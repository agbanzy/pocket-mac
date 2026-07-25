//! JNI bridge: the same Rust agent core, inside an Android app.
//!
//! Android is the one platform where the OS seam cannot live in Rust. Input needs an
//! `AccessibilityService` and capture needs `MediaProjection` — both Android framework APIs that
//! must be driven from Kotlin. So the split is:
//!
//! * **Kotlin** implements capture and input and passes them down as a callback object.
//! * **Rust** runs the loop, the model client, the tool registry and the task store — unchanged
//!   from macOS and Windows.
//!
//! In other words `ComputerBackend` is implemented *upwards* here, calling back into the JVM,
//! whereas on desktop it is implemented directly. Everything above the seam is identical.
//!
//! Kotlin side:
//!
//! ```kotlin
//! object PocketMacAgent {
//!     init { System.loadLibrary("pocketmac_agent_jni") }
//!     external fun runTask(prompt: String, apiKey: String, storeDir: String,
//!                          persona: String?, host: AgentHost): Int
//!     external fun cancel()
//! }
//!
//! interface AgentHost {
//!     fun capture(): ByteArray        // JPEG of the current screen, already downscaled
//!     fun screenWidth(): Int          // the coordinate space those bytes are in
//!     fun screenHeight(): Int
//!     fun execute(actionJson: String) // one action, as JSON
//!     fun onEvent(kind: String, text: String)
//! }
//! ```

use agent_core::{
    run, Action, AgentConfig, AgentError, ComputerBackend, Emitter, EventKind, LlmClient, Result,
    Screenshot, TaskEvent, ToolRegistry,
};
use agent_llm_anthropic::AnthropicClient;
use agent_store_fs::FsTaskStore;
use async_trait::async_trait;
use base64::Engine as _;
use jni::objects::{JByteArray, JClass, JObject, JString, JValue};
use jni::sys::jint;
use jni::{JNIEnv, JavaVM};
use std::sync::atomic::{AtomicBool, Ordering};

static CANCEL: AtomicBool = AtomicBool::new(false);

/// Calls back into the Kotlin `AgentHost` for capture and input.
///
/// Holds a `JavaVM` plus a global ref rather than the borrowed `JNIEnv`: the agent loop is async and
/// runs on tokio worker threads, and a `JNIEnv` is only valid on the thread that produced it. Each
/// call attaches the current thread instead.
struct JvmBackend {
    vm: JavaVM,
    host: jni::objects::GlobalRef,
    size: (u32, u32),
}

impl JvmBackend {
    fn call_int(&self, method: &str) -> Result<i32> {
        let mut env = self
            .vm
            .attach_current_thread()
            .map_err(|e| AgentError::Backend(format!("attach: {e}")))?;
        env.call_method(&self.host, method, "()I", &[])
            .and_then(|v| v.i())
            .map_err(|e| AgentError::Backend(format!("{method}: {e}")))
    }
}

#[async_trait]
impl ComputerBackend for JvmBackend {
    async fn capture(&self) -> Result<Screenshot> {
        let mut env = self
            .vm
            .attach_current_thread()
            .map_err(|e| AgentError::Backend(format!("attach: {e}")))?;
        let value = env
            .call_method(&self.host, "capture", "()[B", &[])
            .map_err(|e| AgentError::Backend(format!("capture: {e}")))?;
        let array: JByteArray =
            value.l().map_err(|e| AgentError::Backend(e.to_string()))?.into();
        let bytes = env
            .convert_byte_array(&array)
            .map_err(|e| AgentError::Backend(format!("capture bytes: {e}")))?;
        Ok(Screenshot {
            data_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
            media_type: "image/jpeg".into(),
            width: self.size.0,
            height: self.size.1,
        })
    }

    async fn execute(&self, action: &Action) -> Result<Option<String>> {
        // Actions cross as JSON so adding one needs no JNI signature change — the Kotlin side
        // switches on `action` exactly as the desktop backend does.
        let json = serde_json::to_string(action)
            .map_err(|e| AgentError::Backend(format!("encode action: {e}")))?;
        let mut env = self
            .vm
            .attach_current_thread()
            .map_err(|e| AgentError::Backend(format!("attach: {e}")))?;
        let arg = env.new_string(json).map_err(|e| AgentError::Backend(e.to_string()))?;
        env.call_method(
            &self.host,
            "execute",
            "(Ljava/lang/String;)V",
            &[JValue::Object(&JObject::from(arg))],
        )
        .map_err(|e| AgentError::Backend(format!("execute: {e}")))?;
        Ok(None)
    }

    fn model_size(&self) -> (u32, u32) {
        self.size
    }
}

/// Streams progress back to Kotlin.
struct JvmEmitter {
    vm: JavaVM,
    host: jni::objects::GlobalRef,
}

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
impl Emitter for JvmEmitter {
    async fn emit(&self, event: TaskEvent) {
        let Ok(mut env) = self.vm.attach_current_thread() else { return };
        let (Ok(kind), Ok(text)) =
            (env.new_string(kind_str(event.kind)), env.new_string(&event.text))
        else {
            return;
        };
        // Progress is best-effort: a UI that failed to take one line must not abort the task.
        let _ = env.call_method(
            &self.host,
            "onEvent",
            "(Ljava/lang/String;Ljava/lang/String;)V",
            &[JValue::Object(&JObject::from(kind)), JValue::Object(&JObject::from(text))],
        );
    }
}

fn jstring_to_string(env: &mut JNIEnv, s: &JString) -> String {
    env.get_string(s).map(|v| v.into()).unwrap_or_default()
}

/// `PocketMacAgent.runTask(...)`. Blocks the calling thread, so call it from a background thread or
/// a coroutine on `Dispatchers.IO` — never Android's main thread.
///
/// Returns 0 on success, non-zero on failure.
#[no_mangle]
pub extern "system" fn Java_com_innoedge_pocketmac_PocketMacAgent_runTask(
    mut env: JNIEnv,
    _class: JClass,
    prompt: JString,
    api_key: JString,
    store_dir: JString,
    persona: JString,
    host: JObject,
) -> jint {
    CANCEL.store(false, Ordering::SeqCst);

    let prompt = jstring_to_string(&mut env, &prompt);
    let api_key = jstring_to_string(&mut env, &api_key);
    let store_dir = jstring_to_string(&mut env, &store_dir);
    let persona = {
        let p = jstring_to_string(&mut env, &persona);
        if p.is_empty() { None } else { Some(p) }
    };

    let (Ok(vm), Ok(host_ref)) = (env.get_java_vm(), env.new_global_ref(&host)) else {
        return 2;
    };
    let Ok(vm2) = env.get_java_vm() else { return 2 };

    // Ask Kotlin for the coordinate space before building the real backend: every action the model
    // returns is expressed in it, so guessing here would mis-place every tap.
    let probe = JvmBackend { vm, host: host_ref.clone(), size: (1, 1) };
    let (Ok(w), Ok(h)) = (probe.call_int("screenWidth"), probe.call_int("screenHeight")) else {
        return 3;
    };
    let backend =
        JvmBackend { vm: probe.vm, host: host_ref.clone(), size: (w.max(1) as u32, h.max(1) as u32) };
    let emitter = JvmEmitter { vm: vm2, host: host_ref };

    let Ok(store) = FsTaskStore::new(&store_dir) else { return 4 };
    let llm = AnthropicClient::new(api_key);
    let registry = ToolRegistry::new();
    let cfg = AgentConfig { persona, ..AgentConfig::default() };

    let Ok(rt) = tokio::runtime::Builder::new_multi_thread().enable_all().build() else {
        return 5;
    };
    let outcome = rt.block_on(async {
        run(
            &cfg,
            &backend as &dyn ComputerBackend,
            &registry,
            &llm as &dyn LlmClient,
            &store,
            &emitter as &dyn Emitter,
            None,
            &prompt,
            &CANCEL,
        )
        .await
    });
    match outcome {
        Ok(_) => 0,
        Err(_) => 1,
    }
}

/// `PocketMacAgent.cancel()` — stop at the next step boundary.
#[no_mangle]
pub extern "system" fn Java_com_innoedge_pocketmac_PocketMacAgent_cancel(
    _env: JNIEnv,
    _class: JClass,
) {
    CANCEL.store(true, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use agent_core::Action;

    #[test]
    fn actions_cross_the_bridge_as_json_kotlin_can_switch_on() {
        // The Kotlin side dispatches on "action", so that field must survive serialization —
        // otherwise every tap would arrive as an unrecognised blob.
        let a = Action::LeftClick { coordinate: [12, 34], text: None };
        let json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&a).unwrap()).unwrap();
        assert_eq!(json["action"], "left_click");
        assert_eq!(json["coordinate"][0], 12);

        let k = Action::Key { text: "cmd+space".into() };
        let json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&k).unwrap()).unwrap();
        assert_eq!(json["action"], "key");
        assert_eq!(json["text"], "cmd+space");
    }
}
