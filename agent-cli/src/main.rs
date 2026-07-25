//! `pocketmac-agent` — run a task on this machine from the command line.
//!
//! The same shared brain the Mac menu-bar helper embeds, as a standalone binary. On Windows and
//! Linux this *is* the host: no GUI to write, no FFI to bridge — the agent loop, the Claude client,
//! the desktop backend, MCP tools, and durable task history in one executable.
//!
//! ```text
//! pocketmac-agent "open the browser and search for flights"
//! pocketmac-agent --history      # recent tasks and how they ended
//! ```
//!
//! The API key comes from ANTHROPIC_API_KEY, or `--key`.

use agent_backend_desktop::DesktopBackend;
use agent_core::{
    register_mcp_server, run, AgentConfig, ComputerBackend, Emitter, EventKind, LlmClient, McpClient,
    Memory, TaskEvent, TaskStore, ToolRegistry,
};
use agent_llm_anthropic::AnthropicClient;
use agent_llm_claude_code::ClaudeCodeClient;
use agent_llm_openai::{provider, OpenAiCompatClient};
use agent_mcp_stdio::McpStdioClient;
use agent_store_fs::{FsMemory, FsTaskStore};
use async_trait::async_trait;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

/// Prints progress as it happens, so a long task isn't a silent cursor.
struct ConsoleEmitter;

#[async_trait]
impl Emitter for ConsoleEmitter {
    async fn emit(&self, event: TaskEvent) {
        let tag = match event.kind {
            EventKind::Started => "▶",
            EventKind::Thinking => "…",
            EventKind::Action => "→",
            EventKind::Done => "✔",
            EventKind::Error => "✖",
        };
        println!("{tag} {}", event.text);
    }
}

/// Per-user data directory, following each platform's convention rather than dumping in $HOME.
fn data_dir() -> PathBuf {
    let base = if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support"))
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
    };
    base.unwrap_or_else(std::env::temp_dir).join("PocketMac")
}

/// Register any MCP servers listed in `<data dir>/mcp.json`, same contract as the Mac helper.
async fn load_mcp(registry: &mut ToolRegistry, dir: &Path) {
    let path = dir.join("mcp.json");
    let Ok(bytes) = std::fs::read(&path) else { return };
    let Ok(cfg) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        eprintln!("warning: {} is not valid JSON; ignoring", path.display());
        return;
    };
    let empty = Vec::new();
    let servers = cfg.get("servers").and_then(|s| s.as_array()).unwrap_or(&empty);
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
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        match McpStdioClient::spawn(id, command, &refs).await {
            Ok(c) => match register_mcp_server(registry, Arc::new(c) as Arc<dyn McpClient>).await {
                Ok(n) => eprintln!("mcp '{id}': {n} tool(s)"),
                Err(e) => eprintln!("mcp '{id}': no tools ({e})"),
            },
            // Never fatal: a broken optional tool must not stop the user's work.
            Err(e) => eprintln!("mcp '{id}': failed to start ({e})"),
        }
    }
}

async fn show_history(store: &FsTaskStore) -> Result<(), Box<dyn std::error::Error>> {
    let tasks = store.list(20).await?;
    if tasks.is_empty() {
        println!("No tasks yet.");
        return Ok(());
    }
    for t in tasks {
        println!("{:?}  {}  ({} events)", t.status, t.prompt, t.events.len());
    }
    Ok(())
}

fn usage() -> ! {
    eprintln!(
        "pocketmac-agent — run a task on this computer\n\n\
         USAGE:\n  \
           pocketmac-agent [--provider <NAME>] [--model <ID>] [--key <KEY>] <TASK>\n  \
           pocketmac-agent --history\n\n\
         PROVIDERS: claude-code (your subscription, no key), claude, grok, openai,\n  \
                    ollama, lm-studio, llama.cpp\n\
         Keys come from ANTHROPIC_API_KEY / XAI_API_KEY / OPENAI_API_KEY, or --key."
    );
    std::process::exit(2)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir = data_dir();
    let store = FsTaskStore::new(dir.join("tasks"))?;

    let mut args = std::env::args().skip(1);
    let mut key = std::env::var("ANTHROPIC_API_KEY").ok();
    let mut persona = None;
    // Claude by default; --provider swaps in any OpenAI-compatible one (grok, openai, ollama…).
    let mut provider_id: Option<String> = std::env::var("POCKETMAC_PROVIDER").ok();
    let mut model_override: Option<String> = None;
    let mut prompt_parts: Vec<String> = Vec::new();

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--history" => return show_history(&store).await,
            "--help" | "-h" => usage(),
            "--key" => key = args.next(),
            "--persona" => persona = args.next(),
            "--provider" => provider_id = args.next(),
            "--model" => model_override = args.next(),
            other => prompt_parts.push(other.to_string()),
        }
    }

    let prompt = prompt_parts.join(" ");
    if prompt.trim().is_empty() {
        usage();
    }
    let backend = DesktopBackend::new()?;
    let (w, h) = backend.model_size();
    eprintln!("screen {w}x{h} (model space) · history in {}", dir.join("tasks").display());

    let mut registry = ToolRegistry::new();
    load_mcp(&mut registry, &dir).await;

    let memory: Option<Arc<dyn Memory>> =
        FsMemory::new(dir.join("memory.json")).ok().map(|m| Arc::new(m) as Arc<dyn Memory>);

    // One seam, two providers: Claude speaks the Messages API, everything else the OpenAI shape.
    let llm: Box<dyn LlmClient> = match provider_id.as_deref() {
        None | Some("claude") | Some("anthropic") => {
            let Some(k) = key.filter(|k| k.starts_with("sk-ant-")) else {
                eprintln!("No Anthropic API key. Set ANTHROPIC_API_KEY, pass --key, \
                           or choose another provider with --provider grok.");
                std::process::exit(2);
            };
            Box::new(AnthropicClient::new(k))
        }
        // Your Claude subscription, via the Claude Code CLI — no API key, no per-token charge.
        Some("claude-code") | Some("subscription") => {
            if !agent_llm_claude_code::available() {
                eprintln!("Claude Code isn't on PATH. Install it, or use --provider claude with a key.");
                std::process::exit(2);
            }
            eprintln!("provider: claude-code (your subscription){}",
                      model_override.as_deref().map(|m| format!(" · model {m}")).unwrap_or_default());
            let mut c = ClaudeCodeClient::new();
            if let Some(m) = model_override.as_deref() { c = c.with_model(m); }
            Box::new(c)
        }
        Some(id) => {
            let Some(p) = provider(id) else {
                eprintln!("Unknown provider '{id}'. Try: claude-code, grok, openai, ollama, lm-studio, llama.cpp.");
                std::process::exit(2);
            };
            match OpenAiCompatClient::from_provider(p, model_override.as_deref(), key.as_deref()) {
                Ok(c) => {
                    eprintln!("provider: {} · model {}", p.id,
                              model_override.as_deref().unwrap_or(p.default_model));
                    Box::new(c)
                }
                Err(e) => { eprintln!("{e}"); std::process::exit(2); }
            }
        }
    };
    let cfg = AgentConfig { persona, ..AgentConfig::default() };
    let cancel = AtomicBool::new(false);

    match run(
        &cfg,
        &backend as &dyn ComputerBackend,
        &registry,
        llm.as_ref(),
        &store as &dyn TaskStore,
        &ConsoleEmitter,
        memory.as_ref(),
        &prompt,
        &cancel,
    )
    .await
    {
        Ok(_) => Ok(()),
        Err(e) => {
            eprintln!("task failed: {e}");
            std::process::exit(1)
        }
    }
}
