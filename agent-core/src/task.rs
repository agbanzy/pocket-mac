//! Work/task management. Every task is persisted with its status and full event stream, so a
//! controller can show history, resume, retry, or queue — the layer the product has none of today.
//! Persistence is a trait; a platform crate can back it with SQLite/JSONL. `InMemoryTaskStore` is
//! the default and the test double.

use crate::types::{AgentError, Result, TaskEvent};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Queued,
    Running,
    Done,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskRecord {
    pub id: String,
    pub prompt: String,
    pub status: TaskStatus,
    pub created_at_unix: u64,
    pub events: Vec<TaskEvent>,
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[async_trait]
pub trait TaskStore: Send + Sync {
    async fn create(&self, prompt: &str) -> Result<String>;
    async fn append(&self, id: &str, event: &TaskEvent) -> Result<()>;
    async fn set_status(&self, id: &str, status: TaskStatus) -> Result<()>;
    async fn get(&self, id: &str) -> Result<Option<TaskRecord>>;
    /// Most-recent-first, capped at `limit`.
    async fn list(&self, limit: usize) -> Result<Vec<TaskRecord>>;
}

#[derive(Default)]
pub struct InMemoryTaskStore {
    inner: Mutex<HashMap<String, TaskRecord>>,
    order: Mutex<Vec<String>>,
}

impl InMemoryTaskStore {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl TaskStore for InMemoryTaskStore {
    async fn create(&self, prompt: &str) -> Result<String> {
        let id = uuid::Uuid::new_v4().to_string();
        let rec = TaskRecord {
            id: id.clone(),
            prompt: prompt.to_string(),
            status: TaskStatus::Queued,
            created_at_unix: now_unix(),
            events: Vec::new(),
        };
        self.inner.lock().unwrap().insert(id.clone(), rec);
        self.order.lock().unwrap().push(id.clone());
        Ok(id)
    }

    async fn append(&self, id: &str, event: &TaskEvent) -> Result<()> {
        let mut map = self.inner.lock().unwrap();
        let rec = map.get_mut(id).ok_or_else(|| AgentError::Store("no such task".into()))?;
        rec.events.push(event.clone());
        Ok(())
    }

    async fn set_status(&self, id: &str, status: TaskStatus) -> Result<()> {
        let mut map = self.inner.lock().unwrap();
        let rec = map.get_mut(id).ok_or_else(|| AgentError::Store("no such task".into()))?;
        rec.status = status;
        Ok(())
    }

    async fn get(&self, id: &str) -> Result<Option<TaskRecord>> {
        Ok(self.inner.lock().unwrap().get(id).cloned())
    }

    async fn list(&self, limit: usize) -> Result<Vec<TaskRecord>> {
        let map = self.inner.lock().unwrap();
        let order = self.order.lock().unwrap();
        Ok(order
            .iter()
            .rev()
            .filter_map(|id| map.get(id).cloned())
            .take(limit)
            .collect())
    }
}
