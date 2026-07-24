//! Durable [`agent_core::TaskStore`] — one JSON file per task under a directory, so a controller can
//! browse history, resume, or retry across restarts. Writes are serialized under a mutex and the
//! whole (short) record is rewritten on change; events are the common mutation. std-only.

use agent_core::{AgentError, Result, TaskEvent, TaskRecord, TaskStatus, TaskStore};
use async_trait::async_trait;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub struct FsTaskStore {
    dir: PathBuf,
    lock: Mutex<()>,
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl FsTaskStore {
    pub fn new(dir: impl Into<PathBuf>) -> Result<Self> {
        let dir = dir.into();
        std::fs::create_dir_all(&dir).map_err(|e| AgentError::Store(e.to_string()))?;
        Ok(Self { dir, lock: Mutex::new(()) })
    }

    fn path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    fn read_rec(&self, id: &str) -> Result<TaskRecord> {
        let bytes = std::fs::read(self.path(id))
            .map_err(|_| AgentError::Store(format!("no such task: {id}")))?;
        serde_json::from_slice(&bytes).map_err(|e| AgentError::Store(e.to_string()))
    }

    fn write_rec(&self, rec: &TaskRecord) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(rec).map_err(|e| AgentError::Store(e.to_string()))?;
        // Atomic-ish: write to a temp then rename, so a crash mid-write can't corrupt the record.
        let tmp = self.dir.join(format!(".{}.tmp", rec.id));
        std::fs::write(&tmp, &bytes).map_err(|e| AgentError::Store(e.to_string()))?;
        std::fs::rename(&tmp, self.path(&rec.id)).map_err(|e| AgentError::Store(e.to_string()))
    }
}

#[async_trait]
impl TaskStore for FsTaskStore {
    async fn create(&self, prompt: &str) -> Result<String> {
        let _g = self.lock.lock().unwrap();
        let id = uuid_like();
        let rec = TaskRecord {
            id: id.clone(),
            prompt: prompt.to_string(),
            status: TaskStatus::Queued,
            created_at_unix: now_unix(),
            events: Vec::new(),
        };
        self.write_rec(&rec)?;
        Ok(id)
    }

    async fn append(&self, id: &str, event: &TaskEvent) -> Result<()> {
        let _g = self.lock.lock().unwrap();
        let mut rec = self.read_rec(id)?;
        rec.events.push(event.clone());
        self.write_rec(&rec)
    }

    async fn set_status(&self, id: &str, status: TaskStatus) -> Result<()> {
        let _g = self.lock.lock().unwrap();
        let mut rec = self.read_rec(id)?;
        rec.status = status;
        self.write_rec(&rec)
    }

    async fn get(&self, id: &str) -> Result<Option<TaskRecord>> {
        let _g = self.lock.lock().unwrap();
        Ok(self.read_rec(id).ok())
    }

    async fn list(&self, limit: usize) -> Result<Vec<TaskRecord>> {
        let _g = self.lock.lock().unwrap();
        let mut recs = read_all(&self.dir);
        recs.sort_by(|a, b| b.created_at_unix.cmp(&a.created_at_unix));
        recs.truncate(limit);
        Ok(recs)
    }
}

fn read_all(dir: &Path) -> Vec<TaskRecord> {
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) == Some("json") {
                if let Ok(bytes) = std::fs::read(&p) {
                    if let Ok(rec) = serde_json::from_slice::<TaskRecord>(&bytes) {
                        out.push(rec);
                    }
                }
            }
        }
    }
    out
}

/// A UUID-ish id without pulling the uuid crate here: time + a process-local counter.
fn uuid_like() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:x}-{:x}", t, N.fetch_add(1, Ordering::Relaxed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persists_across_reopen() {
        let dir = std::env::temp_dir().join(format!("pma-store-{}", uuid_like()));
        // First store instance: create + record a task.
        let id = {
            let store = FsTaskStore::new(&dir).unwrap();
            let id = pollster::block_on(store.create("do a thing")).unwrap();
            pollster::block_on(store.append(&id, &TaskEvent {
                kind: agent_core::EventKind::Action,
                text: "clicked".into(),
            }))
            .unwrap();
            pollster::block_on(store.set_status(&id, TaskStatus::Done)).unwrap();
            id
        };
        // Fresh instance over the same dir: the task is still there.
        let store2 = FsTaskStore::new(&dir).unwrap();
        let rec = pollster::block_on(store2.get(&id)).unwrap().unwrap();
        assert_eq!(rec.status, TaskStatus::Done);
        assert_eq!(rec.events.len(), 1);
        assert_eq!(pollster::block_on(store2.list(10)).unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
