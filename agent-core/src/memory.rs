//! Light, self-aware memory.
//!
//! Two halves, both deliberately small because everything here rides in the cached prompt prefix
//! on **every** turn — memory that grows without bound crowds out the screenshots the model
//! actually reasons over, and quietly makes the agent worse.
//!
//! * **Environment** — what the agent knows about the machine it lives on (OS, screen, user). Facts,
//!   gathered fresh each run, never persisted.
//! * **Recall** — what it has been told to remember across runs ("she prefers Safari", "the deploy
//!   script lives in ops/"). Persisted, capped, and writable by the model itself through the
//!   `remember` tool.

use crate::llm::ContentBlock;
use crate::tool::Tool;
use crate::types::{AgentError, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// One remembered fact. Keyed so a later run can correct it rather than pile on duplicates.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemoryEntry {
    pub key: String,
    pub value: String,
    pub updated_at_unix: u64,
}

/// How many facts to surface in the prompt. Small on purpose — see the module note.
pub const RECALL_LIMIT: usize = 24;

#[async_trait]
pub trait Memory: Send + Sync {
    /// Most-recently-updated first, capped at `limit`.
    async fn recall(&self, limit: usize) -> Result<Vec<MemoryEntry>>;
    /// Insert or replace by key.
    async fn remember(&self, key: &str, value: &str) -> Result<()>;
    async fn forget(&self, key: &str) -> Result<()>;
}

/// Facts about the machine, so the agent isn't guessing at its own situation. Filled in by the host
/// (it knows the real OS and screen); `describe` renders the prompt fragment.
#[derive(Clone, Debug, Default)]
pub struct Environment {
    pub os: String,
    pub os_version: String,
    pub hostname: String,
    pub user: String,
    /// Model-space screen size the coordinates use.
    pub screen: (u32, u32),
}

impl Environment {
    /// Gather what the standard library and environment can tell us. Hosts may override fields.
    pub fn detect(screen: (u32, u32)) -> Self {
        let os = std::env::consts::OS.to_string();
        let user = std::env::var("USER")
            .or_else(|_| std::env::var("USERNAME"))
            .unwrap_or_default();
        let hostname = std::env::var("HOSTNAME")
            .or_else(|_| std::env::var("COMPUTERNAME"))
            .unwrap_or_default();
        Environment { os, os_version: String::new(), hostname, user, screen }
    }

    pub fn describe(&self) -> String {
        let mut lines = vec![format!("- operating system: {}{}", self.os,
            if self.os_version.is_empty() { String::new() } else { format!(" {}", self.os_version) })];
        if !self.user.is_empty() {
            lines.push(format!("- signed in as: {}", self.user));
        }
        if !self.hostname.is_empty() {
            lines.push(format!("- machine: {}", self.hostname));
        }
        lines.push(format!("- screen: {}x{} in the coordinate space you are given",
                           self.screen.0, self.screen.1));
        lines.join("\n")
    }
}

/// Render recalled facts for the prompt. Empty string when there is nothing to say, so the prompt
/// doesn't carry a pointless empty heading.
pub fn describe_recall(entries: &[MemoryEntry]) -> String {
    if entries.is_empty() {
        return String::new();
    }
    entries
        .iter()
        .map(|e| format!("- {}: {}", e.key, e.value))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Lets the model write to memory itself: "remember that the staging URL is …". Without this,
/// memory would only ever hold what a human typed in, which is not self-aware in any useful sense.
pub struct RememberTool {
    memory: Arc<dyn Memory>,
}

impl RememberTool {
    pub fn new(memory: Arc<dyn Memory>) -> Self {
        Self { memory }
    }
}

#[async_trait]
impl Tool for RememberTool {
    fn name(&self) -> &str {
        "remember"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "name": "remember",
            "description": "Save a durable fact about this machine or the user, so future tasks \
                            start informed. Use a short stable key so a later correction replaces \
                            the fact instead of duplicating it. Record preferences, locations, and \
                            names — not transient state like what is currently on screen.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "key": { "type": "string", "description": "Short stable identifier, e.g. 'preferred browser'." },
                    "value": { "type": "string", "description": "The fact, in one sentence." },
                    "forget": { "type": "boolean", "description": "Set true to delete this key instead." }
                },
                "required": ["key"]
            }
        })
    }

    async fn call(&self, input: &serde_json::Value) -> Result<Vec<ContentBlock>> {
        let key = input
            .get("key")
            .and_then(|v| v.as_str())
            .ok_or_else(|| AgentError::Tool("remember: 'key' is required".into()))?;

        if input.get("forget").and_then(|v| v.as_bool()).unwrap_or(false) {
            self.memory.forget(key).await?;
            return Ok(vec![ContentBlock::text(format!("Forgot '{key}'."))]);
        }

        let value = input
            .get("value")
            .and_then(|v| v.as_str())
            .ok_or_else(|| AgentError::Tool("remember: 'value' is required unless forgetting".into()))?;
        self.memory.remember(key, value).await?;
        Ok(vec![ContentBlock::text(format!("Noted: {key} — {value}"))])
    }
}

/// In-memory implementation; the default when a host has nowhere to persist.
#[derive(Default)]
pub struct InMemoryMemory {
    entries: std::sync::Mutex<Vec<MemoryEntry>>,
}

impl InMemoryMemory {
    pub fn new() -> Self {
        Self::default()
    }
}

pub(crate) fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[async_trait]
impl Memory for InMemoryMemory {
    async fn recall(&self, limit: usize) -> Result<Vec<MemoryEntry>> {
        let mut v = self.entries.lock().unwrap().clone();
        v.sort_by(|a, b| b.updated_at_unix.cmp(&a.updated_at_unix));
        v.truncate(limit);
        Ok(v)
    }

    async fn remember(&self, key: &str, value: &str) -> Result<()> {
        let mut v = self.entries.lock().unwrap();
        let entry = MemoryEntry {
            key: key.to_string(),
            value: value.to_string(),
            updated_at_unix: now_unix(),
        };
        match v.iter_mut().find(|e| e.key == key) {
            Some(existing) => *existing = entry,
            None => v.push(entry),
        }
        Ok(())
    }

    async fn forget(&self, key: &str) -> Result<()> {
        self.entries.lock().unwrap().retain(|e| e.key != key);
        Ok(())
    }
}
