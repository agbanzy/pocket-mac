//! # agent-core
//!
//! The portable computer-use agent brain for Pocket Mac — one loop that runs on macOS, Windows,
//! and Android. It is deliberately dependency-inverted: the loop depends only on four seams, each
//! implemented by a small platform crate.
//!
//! | Seam | Trait | Provided by |
//! |------|-------|-------------|
//! | Model | [`LlmClient`] | an Anthropic-over-HTTP crate |
//! | OS control | [`ComputerBackend`] | macOS / Win32 / Android input+capture |
//! | Skills | [`McpClient`] → [`ToolRegistry`] | MCP transports (stdio/SSE/HTTP) |
//! | Persistence | [`TaskStore`] | SQLite/JSONL (or the in-memory default) |
//!
//! Adding a platform = implement [`ComputerBackend`]. Adding a skill = point an [`McpClient`] at a
//! server. Adding JARVIS = set [`AgentConfig::persona`] and stream events to voice/chat. The loop
//! itself never changes.

pub mod agent;
pub mod backend;
pub mod llm;
pub mod memory;
pub mod mcp;
pub mod task;
pub mod tool;
pub mod types;

pub use agent::{run, AgentConfig, Emitter};
pub use backend::{computer_tool_schema, ComputerBackend};
pub use memory::{describe_recall, Environment, InMemoryMemory, Memory, MemoryEntry, RememberTool, RECALL_LIMIT};
pub use llm::{ContentBlock, ImageSource, LlmClient, LlmRequest, LlmResponse, Message, Usage};
pub use mcp::{register_mcp_server, McpClient, McpTool, McpToolDef};
pub use task::{InMemoryTaskStore, TaskRecord, TaskStatus, TaskStore};
pub use tool::{Tool, ToolRegistry};
pub use types::{Action, AgentError, EventKind, Result, Screenshot, TaskEvent};

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::atomic::AtomicBool;
    use std::sync::Mutex;

    struct MockBackend;
    #[async_trait]
    impl ComputerBackend for MockBackend {
        async fn capture(&self) -> Result<Screenshot> {
            Ok(Screenshot {
                data_base64: "AAAA".into(),
                media_type: "image/jpeg".into(),
                width: 1024,
                height: 768,
            })
        }
        async fn execute(&self, _a: &Action) -> Result<Option<String>> {
            Ok(None)
        }
        fn model_size(&self) -> (u32, u32) {
            (1024, 768)
        }
    }

    /// Scripted model: turn 1 requests a click, turn 2 ends the task.
    struct ScriptLlm {
        calls: Mutex<u32>,
    }
    #[async_trait]
    impl LlmClient for ScriptLlm {
        async fn complete(&self, _req: &LlmRequest) -> Result<LlmResponse> {
            let mut n = self.calls.lock().unwrap();
            *n += 1;
            if *n == 1 {
                Ok(LlmResponse {
                    content: vec![ContentBlock::ToolUse {
                        id: "t1".into(),
                        name: "computer".into(),
                        input: serde_json::json!({"action":"left_click","coordinate":[10,20]}),
                    }],
                    stop_reason: "tool_use".into(),
                    usage: Usage::default(),
                })
            } else {
                Ok(LlmResponse {
                    content: vec![ContentBlock::text("All done.")],
                    stop_reason: "end_turn".into(),
                    usage: Usage::default(),
                })
            }
        }
    }

    struct CollectEmitter {
        events: Mutex<Vec<TaskEvent>>,
    }
    #[async_trait]
    impl Emitter for CollectEmitter {
        async fn emit(&self, ev: TaskEvent) {
            self.events.lock().unwrap().push(ev);
        }
    }

    #[test]
    fn loop_runs_a_task_end_to_end() {
        let backend = MockBackend;
        let registry = ToolRegistry::new();
        let llm = ScriptLlm { calls: Mutex::new(0) };
        let store = InMemoryTaskStore::new();
        let emitter = CollectEmitter { events: Mutex::new(Vec::new()) };
        let cancel = AtomicBool::new(false);
        let cfg = AgentConfig::default();

        let out = pollster::block_on(run(
            &cfg, &backend, &registry, &llm, &store, &emitter, None, "click something", &cancel,
        ))
        .unwrap();

        assert_eq!(out, "All done.");
        let kinds: Vec<_> = emitter.events.lock().unwrap().iter().map(|e| e.kind).collect();
        assert!(kinds.contains(&EventKind::Started));
        assert!(kinds.contains(&EventKind::Action));
        assert!(kinds.contains(&EventKind::Done));

        let list = pollster::block_on(store.list(10)).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].status, TaskStatus::Done);
    }
}
