//! C ABI for the Pocket Mac agent. One entry point that any native host — the Swift menu-bar
//! helper today, a Windows service or an Android JNI shim tomorrow — can call to run a task on the
//! shared Rust brain: `agent-core` + Anthropic client + desktop backend + durable task store.
//!
//! ```c
//! typedef void (*pm_event_cb)(const char *kind, const char *text, void *ctx);
//! int32_t pm_agent_run(const char *prompt, const char *api_key, const char *store_dir,
//!                      const char *persona, pm_event_cb cb, void *ctx);
//! void    pm_agent_cancel(void);
//! const char *pm_agent_last_error(void);
//! ```
//!
//! Threading: `pm_agent_run` blocks the calling thread until the task ends, driving an internal
//! multi-thread tokio runtime. Hosts should call it off their UI thread. Progress arrives on the
//! callback from a worker thread — hop to your UI queue before touching UI.

use agent_backend_desktop::DesktopBackend;
use agent_core::{
    register_mcp_server, run, AgentConfig, ComputerBackend, Emitter, EventKind, LlmClient, McpClient,
    Memory, TaskEvent, TaskStore, ToolRegistry,
};
use agent_llm_anthropic::AnthropicClient;
use agent_mcp_stdio::McpStdioClient;
use agent_store_fs::{FsMemory, FsTaskStore};
use async_trait::async_trait;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// `void (*)(const char *kind, const char *text, void *ctx)`
pub type EventCallback = extern "C" fn(*const c_char, *const c_char, *mut c_void);

/// Cancellation is process-wide: one agent task at a time per host, matching the product (one
/// machine, one active task). `pm_agent_cancel` flips this; the loop polls it between steps.
static CANCEL: AtomicBool = AtomicBool::new(false);

fn last_error_slot() -> &'static Mutex<Option<CString>> {
    static SLOT: OnceLock<Mutex<Option<CString>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

fn set_last_error(msg: impl Into<Vec<u8>>) {
    if let Ok(mut slot) = last_error_slot().lock() {
        *slot = CString::new(msg).ok();
    }
}

/// Bridges core events to the host callback. The raw `ctx` pointer is opaque to us; the host owns
/// its lifetime and must keep it alive for the duration of `pm_agent_run`.
struct CallbackEmitter {
    cb: EventCallback,
    ctx: usize,
}

// SAFETY: `ctx` is an opaque host pointer carried as a usize so the struct is Send + Sync. The host
// contract is that it stays valid for the whole call and that the callback is thread-safe.
unsafe impl Send for CallbackEmitter {}
unsafe impl Sync for CallbackEmitter {}

fn kind_str(kind: EventKind) -> &'static str {
    match kind {
        EventKind::Started => "started",
        EventKind::Thinking => "thinking",
        EventKind::Action => "action",
        EventKind::Done => "done",
        EventKind::Error => "error",
    }
}

#[async_trait]
impl Emitter for CallbackEmitter {
    async fn emit(&self, event: TaskEvent) {
        let kind = CString::new(kind_str(event.kind)).unwrap_or_default();
        let text = CString::new(event.text.replace('\0', " ")).unwrap_or_default();
        (self.cb)(kind.as_ptr(), text.as_ptr(), self.ctx as *mut c_void);
    }
}

/// Spawn the MCP servers listed in `mcp.json` (a sibling of the task-store directory) and register
/// their tools, so the agent can do more than drive the screen — read files, query APIs, whatever a
/// server exposes. Shape:
///
/// ```json
/// { "servers": [ { "id": "fs", "command": "npx",
///                  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path"] } ] }
/// ```
///
/// A server that fails to start is skipped with a log line rather than failing the task: a broken
/// optional tool must not stop the user's work. Returns how many tools were registered.
async fn register_configured_mcp_servers(registry: &mut ToolRegistry, store_dir: &str) -> usize {
    let config_path = Path::new(store_dir)
        .parent()
        .unwrap_or(Path::new(store_dir))
        .join("mcp.json");
    let Ok(bytes) = std::fs::read(&config_path) else { return 0 };
    let Ok(cfg) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        eprintln!("pocketmac: {} is not valid JSON; ignoring", config_path.display());
        return 0;
    };
    let Some(servers) = cfg.get("servers").and_then(|s| s.as_array()) else { return 0 };

    let mut total = 0;
    for server in servers {
        let (Some(id), Some(command)) = (
            server.get("id").and_then(|v| v.as_str()),
            server.get("command").and_then(|v| v.as_str()),
        ) else {
            continue;
        };
        let args: Vec<String> = server
            .get("args")
            .and_then(|a| a.as_array())
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();

        match McpStdioClient::spawn(id, command, &arg_refs).await {
            Ok(client) => match register_mcp_server(registry, Arc::new(client) as Arc<dyn McpClient>).await {
                Ok(n) => {
                    total += n;
                    eprintln!("pocketmac: mcp '{id}' registered {n} tool(s)");
                }
                Err(e) => eprintln!("pocketmac: mcp '{id}' listed no tools: {e}"),
            },
            Err(e) => eprintln!("pocketmac: mcp '{id}' failed to start: {e}"),
        }
    }
    total
}

/// Borrow a C string as `&str`; `None` for null or invalid UTF-8.
///
/// # Safety
/// `p` must be null or point to a NUL-terminated string valid for this call.
unsafe fn opt_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// Run one task to completion. Returns `0` on success, non-zero on failure (see
/// `pm_agent_last_error`). Blocks until the task finishes, fails, or is cancelled.
///
/// # Safety
/// All pointer arguments must be null or valid NUL-terminated strings for the duration of the call,
/// and `cb` must be safe to invoke from a worker thread with `ctx`.
#[no_mangle]
pub unsafe extern "C" fn pm_agent_run(
    prompt: *const c_char,
    api_key: *const c_char,
    store_dir: *const c_char,
    persona: *const c_char,
    cb: EventCallback,
    ctx: *mut c_void,
) -> i32 {
    let Some(prompt) = (unsafe { opt_str(prompt) }) else {
        set_last_error("prompt is required");
        return 2;
    };
    let Some(api_key) = (unsafe { opt_str(api_key) }) else {
        set_last_error("api_key is required");
        return 2;
    };
    let store_dir = unsafe { opt_str(store_dir) }.map(str::to_string).unwrap_or_else(|| {
        std::env::temp_dir().join("pocketmac-tasks").to_string_lossy().into_owned()
    });
    let persona = unsafe { opt_str(persona) }.map(str::to_string);

    CANCEL.store(false, Ordering::SeqCst);

    let backend = match DesktopBackend::new() {
        Ok(b) => b,
        Err(e) => {
            set_last_error(format!("backend: {e}"));
            return 3;
        }
    };
    let store = match FsTaskStore::new(&store_dir) {
        Ok(s) => s,
        Err(e) => {
            set_last_error(format!("store: {e}"));
            return 4;
        }
    };
    let llm = AnthropicClient::new(api_key);
    let emitter = CallbackEmitter { cb, ctx: ctx as usize };
    let registry = ToolRegistry::new();   // MCP servers are added inside the runtime below
    let cfg = AgentConfig { persona, ..AgentConfig::default() };

    let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            set_last_error(format!("runtime: {e}"));
            return 5;
        }
    };

    // Memory lives beside the task store, so history and knowledge move together.
    let memory: Option<Arc<dyn Memory>> = Path::new(&store_dir)
        .parent()
        .map(|d| d.join("memory.json"))
        .and_then(|p| FsMemory::new(p).ok())
        .map(|m| Arc::new(m) as Arc<dyn Memory>);

    let outcome = rt.block_on(async {
        let mut registry = registry;
        register_configured_mcp_servers(&mut registry, &store_dir).await;
        run(
            &cfg,
            &backend as &dyn ComputerBackend,
            &registry,
            &llm as &dyn LlmClient,
            &store as &dyn TaskStore,
            &emitter as &dyn Emitter,
            memory.as_ref(),
            prompt,
            &CANCEL,
        )
        .await
    });

    match outcome {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(e.to_string());
            1
        }
    }
}

/// Ask the in-flight task to stop at the next step boundary.
#[no_mangle]
pub extern "C" fn pm_agent_cancel() {
    CANCEL.store(true, Ordering::SeqCst);
}

/// Last error message, or null if none. Borrowed — valid until the next failing call.
#[no_mangle]
pub extern "C" fn pm_agent_last_error() -> *const c_char {
    last_error_slot()
        .lock()
        .ok()
        .and_then(|slot| slot.as_ref().map(|s| s.as_ptr()))
        .unwrap_or(std::ptr::null())
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn noop(_k: *const c_char, _t: *const c_char, _c: *mut c_void) {}

    #[test]
    fn missing_prompt_reports_an_error() {
        let code = unsafe {
            pm_agent_run(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                noop,
                std::ptr::null_mut(),
            )
        };
        assert_eq!(code, 2);
        let err = pm_agent_last_error();
        assert!(!err.is_null());
        let msg = unsafe { CStr::from_ptr(err) }.to_string_lossy().into_owned();
        assert!(msg.contains("prompt"), "unexpected: {msg}");
    }

    #[test]
    fn cancel_sets_the_flag_and_is_idempotent() {
        pm_agent_cancel();
        pm_agent_cancel();
        assert!(CANCEL.load(Ordering::SeqCst));
        CANCEL.store(false, Ordering::SeqCst);
    }
}
