//! Durable [`agent_core::Memory`] — one JSON file the agent reads at the start of every task and
//! writes through the `remember` tool. Small by design: it holds facts, not history (that's the
//! `TaskStore`), and the loop only surfaces the most recent `RECALL_LIMIT` of them.

use agent_core::{AgentError, Memory, MemoryEntry, Result};
use async_trait::async_trait;
use std::path::PathBuf;
use std::sync::Mutex;

/// Hard cap on stored facts. Beyond this the oldest are dropped: unbounded memory would grow the
/// cached prompt prefix forever and slowly starve the model of room to reason.
const MAX_ENTRIES: usize = 200;

pub struct FsMemory {
    path: PathBuf,
    lock: Mutex<()>,
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl FsMemory {
    /// `path` is the JSON file itself, e.g. `<data dir>/memory.json`.
    pub fn new(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| AgentError::Store(e.to_string()))?;
        }
        Ok(Self { path, lock: Mutex::new(()) })
    }

    fn load(&self) -> Vec<MemoryEntry> {
        std::fs::read(&self.path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn save(&self, mut entries: Vec<MemoryEntry>) -> Result<()> {
        entries.sort_by(|a, b| b.updated_at_unix.cmp(&a.updated_at_unix));
        entries.truncate(MAX_ENTRIES);
        let bytes = serde_json::to_vec_pretty(&entries).map_err(|e| AgentError::Store(e.to_string()))?;
        // temp + rename, so a crash mid-write can't leave the agent with corrupt memory
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, &bytes).map_err(|e| AgentError::Store(e.to_string()))?;
        std::fs::rename(&tmp, &self.path).map_err(|e| AgentError::Store(e.to_string()))
    }
}

#[async_trait]
impl Memory for FsMemory {
    async fn recall(&self, limit: usize) -> Result<Vec<MemoryEntry>> {
        let _g = self.lock.lock().unwrap();
        let mut v = self.load();
        v.sort_by(|a, b| b.updated_at_unix.cmp(&a.updated_at_unix));
        v.truncate(limit);
        Ok(v)
    }

    async fn remember(&self, key: &str, value: &str) -> Result<()> {
        let _g = self.lock.lock().unwrap();
        let mut v = self.load();
        let entry = MemoryEntry {
            key: key.to_string(),
            value: value.to_string(),
            updated_at_unix: now_unix(),
        };
        // Replace by key so a correction supersedes the old fact instead of contradicting it.
        match v.iter_mut().find(|e| e.key == key) {
            Some(existing) => *existing = entry,
            None => v.push(entry),
        }
        self.save(v)
    }

    async fn forget(&self, key: &str) -> Result<()> {
        let _g = self.lock.lock().unwrap();
        let mut v = self.load();
        v.retain(|e| e.key != key);
        self.save(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remembers_corrects_and_forgets_across_reopen() {
        let dir = std::env::temp_dir().join(format!("pm-mem-{}", now_unix()));
        let path = dir.join("memory.json");

        {
            let m = FsMemory::new(&path).unwrap();
            pollster::block_on(m.remember("preferred browser", "Safari")).unwrap();
            pollster::block_on(m.remember("project dir", "~/Desktop/Pocket Mac")).unwrap();
            // A correction must replace, not duplicate — otherwise the prompt carries both.
            pollster::block_on(m.remember("preferred browser", "Firefox")).unwrap();
        }

        let m2 = FsMemory::new(&path).unwrap();
        let all = pollster::block_on(m2.recall(50)).unwrap();
        assert_eq!(all.len(), 2, "correction should replace, not append");
        let browser = all.iter().find(|e| e.key == "preferred browser").unwrap();
        assert_eq!(browser.value, "Firefox");

        pollster::block_on(m2.forget("project dir")).unwrap();
        assert_eq!(pollster::block_on(m2.recall(50)).unwrap().len(), 1);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
