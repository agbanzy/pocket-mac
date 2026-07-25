//! Durable [`agent_core::ScheduleStore`] — one JSON file holding every scheduled task, so a
//! morning briefing survives a reboot. Same atomic temp+rename discipline as the task store: a
//! crash mid-write must not leave the schedule unreadable, or the assistant silently stops working.

use agent_core::{AgentError, Result, ScheduleStore, ScheduledTask};
use async_trait::async_trait;
use std::path::PathBuf;
use std::sync::Mutex;

pub struct FsScheduleStore {
    path: PathBuf,
    lock: Mutex<()>,
}

impl FsScheduleStore {
    /// `path` is the JSON file itself, e.g. `<data dir>/schedule.json`.
    pub fn new(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| AgentError::Store(e.to_string()))?;
        }
        Ok(Self { path, lock: Mutex::new(()) })
    }

    fn load(&self) -> Vec<ScheduledTask> {
        std::fs::read(&self.path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn save(&self, tasks: &[ScheduledTask]) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(tasks).map_err(|e| AgentError::Store(e.to_string()))?;
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, &bytes).map_err(|e| AgentError::Store(e.to_string()))?;
        std::fs::rename(&tmp, &self.path).map_err(|e| AgentError::Store(e.to_string()))
    }
}

#[async_trait]
impl ScheduleStore for FsScheduleStore {
    async fn list(&self) -> Result<Vec<ScheduledTask>> {
        let _g = self.lock.lock().unwrap();
        Ok(self.load())
    }

    async fn upsert(&self, task: &ScheduledTask) -> Result<()> {
        let _g = self.lock.lock().unwrap();
        let mut v = self.load();
        match v.iter_mut().find(|t| t.id == task.id) {
            Some(existing) => *existing = task.clone(),
            None => v.push(task.clone()),
        }
        self.save(&v)
    }

    async fn remove(&self, id: &str) -> Result<()> {
        let _g = self.lock.lock().unwrap();
        let mut v = self.load();
        v.retain(|t| t.id != id);
        self.save(&v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_core::{new_task, Cadence};

    #[test]
    fn schedules_survive_a_restart_and_update_in_place() {
        let dir = std::env::temp_dir().join(format!("pm-sched-{}", std::process::id()));
        let path = dir.join("schedule.json");

        {
            let s = FsScheduleStore::new(&path).unwrap();
            let t = new_task("a", "morning briefing", Cadence::Weekdays { hour: 8, minute: 0 }, 0, 0);
            pollster::block_on(s.upsert(&t)).unwrap();
        }

        // A fresh store over the same file sees it — the whole point of persisting.
        let s2 = FsScheduleStore::new(&path).unwrap();
        let all = pollster::block_on(s2.list()).unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].prompt, "morning briefing");

        // Upsert must replace by id, not append a duplicate that would fire twice.
        let mut edited = all[0].clone();
        edited.enabled = false;
        pollster::block_on(s2.upsert(&edited)).unwrap();
        let all = pollster::block_on(s2.list()).unwrap();
        assert_eq!(all.len(), 1, "upsert must replace, not duplicate");
        assert!(!all[0].enabled);

        pollster::block_on(s2.remove("a")).unwrap();
        assert!(pollster::block_on(s2.list()).unwrap().is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
