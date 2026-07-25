//! Recurring and one-off tasks — the "does things without being asked" half of the assistant.
//!
//! Deliberately not cron. Cron syntax is precise and unreadable, and the useful cases here are few:
//! every weekday morning, every hour, once at a time. A small enum covers them, survives a restart
//! as plain JSON, and can be rendered in a phone UI without a parser.

use crate::types::{AgentError, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// When a scheduled task should fire. Times are local to the machine running it — a morning
/// briefing means *your* morning, not UTC's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Cadence {
    /// Fire once at this instant, then delete itself.
    Once { at_unix: u64 },
    /// Every day at hour:minute.
    Daily { hour: u8, minute: u8 },
    /// Monday–Friday at hour:minute. The common "morning briefing" case.
    Weekdays { hour: u8, minute: u8 },
    /// Every N hours from the moment it was created.
    EveryHours { hours: u8 },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScheduledTask {
    pub id: String,
    /// The natural-language task, exactly as a typed one.
    pub prompt: String,
    pub cadence: Cadence,
    pub enabled: bool,
    /// Unix seconds of the next run. Stored rather than recomputed so a missed window is visible
    /// and the machine can decide whether to catch up or skip.
    pub next_run_unix: u64,
    pub last_run_unix: Option<u64>,
    /// Outcome of the last run, so the phone can show "failed 3 hours ago" instead of nothing.
    pub last_outcome: Option<String>,
}

#[async_trait]
pub trait ScheduleStore: Send + Sync {
    async fn list(&self) -> Result<Vec<ScheduledTask>>;
    async fn upsert(&self, task: &ScheduledTask) -> Result<()>;
    async fn remove(&self, id: &str) -> Result<()>;
}

/// Civil-time helpers. `chrono` would be one more dependency for arithmetic this small, so the few
/// pieces needed are derived from the Unix epoch directly.
mod civil {
    /// Days since the epoch → (year, month, day). Howard Hinnant's civil_from_days.
    pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
        let z = z + 719_468;
        let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
        let doe = (z - era * 146_097) as u64;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
        let y = yoe as i64 + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
        let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
        (if m <= 2 { y + 1 } else { y }, m, d)
    }

    /// 0 = Sunday … 6 = Saturday. 1970-01-01 was a Thursday.
    pub fn weekday_from_days(z: i64) -> u32 {
        ((z % 7 + 11) % 7) as u32
    }
}

/// Seconds in a day.
const DAY: u64 = 86_400;

/// Compute the next firing time strictly after `after`.
///
/// `utc_offset_seconds` is the machine's offset from UTC, so "08:00" means eight in the morning
/// where the user is. Passing 0 gives UTC behaviour, which is what tests use.
pub fn next_run(cadence: Cadence, after_unix: u64, utc_offset_seconds: i64) -> u64 {
    match cadence {
        Cadence::Once { at_unix } => at_unix,
        Cadence::EveryHours { hours } => {
            let step = (hours.max(1) as u64) * 3600;
            after_unix + step
        }
        Cadence::Daily { hour, minute } => {
            next_clock_time(after_unix, hour, minute, utc_offset_seconds, |_| true)
        }
        Cadence::Weekdays { hour, minute } => {
            next_clock_time(after_unix, hour, minute, utc_offset_seconds, |wd| {
                (1..=5).contains(&wd) // Monday..Friday
            })
        }
    }
}

/// Walk forward day by day until the local clock time is in the future and the day is accepted.
/// Bounded at ~2 weeks so a predicate that never matches can't spin forever.
fn next_clock_time(
    after_unix: u64,
    hour: u8,
    minute: u8,
    offset: i64,
    day_ok: impl Fn(u32) -> bool,
) -> u64 {
    let local_now = after_unix as i64 + offset;
    let local_day = local_now.div_euclid(DAY as i64);
    let target_secs = (hour.min(23) as i64) * 3600 + (minute.min(59) as i64) * 60;

    for step in 0..15 {
        let day = local_day + step;
        let candidate_local = day * DAY as i64 + target_secs;
        if candidate_local <= local_now {
            continue; // already passed today
        }
        if !day_ok(civil::weekday_from_days(day)) {
            continue;
        }
        return (candidate_local - offset).max(0) as u64;
    }
    // Unreachable for the cadences above; fall back to a day out rather than looping.
    after_unix + DAY
}

/// Advance a task past `now`, returning it ready to store. A one-off is reported as spent so the
/// caller can delete it rather than firing it forever.
pub fn advance(task: &mut ScheduledTask, now_unix: u64, utc_offset_seconds: i64) -> bool {
    task.last_run_unix = Some(now_unix);
    match task.cadence {
        Cadence::Once { .. } => true, // spent
        other => {
            task.next_run_unix = next_run(other, now_unix, utc_offset_seconds);
            false
        }
    }
}

/// Tasks that are enabled and due at `now`.
pub fn due(tasks: &[ScheduledTask], now_unix: u64) -> Vec<ScheduledTask> {
    tasks
        .iter()
        .filter(|t| t.enabled && t.next_run_unix <= now_unix)
        .cloned()
        .collect()
}

/// Build a task with its first run already computed.
pub fn new_task(
    id: impl Into<String>,
    prompt: impl Into<String>,
    cadence: Cadence,
    now_unix: u64,
    utc_offset_seconds: i64,
) -> ScheduledTask {
    ScheduledTask {
        id: id.into(),
        prompt: prompt.into(),
        cadence,
        enabled: true,
        next_run_unix: next_run(cadence, now_unix, utc_offset_seconds),
        last_run_unix: None,
        last_outcome: None,
    }
}

/// In-memory store; the default and the test double.
#[derive(Default)]
pub struct InMemoryScheduleStore {
    tasks: std::sync::Mutex<Vec<ScheduledTask>>,
}

impl InMemoryScheduleStore {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl ScheduleStore for InMemoryScheduleStore {
    async fn list(&self) -> Result<Vec<ScheduledTask>> {
        Ok(self.tasks.lock().map_err(|_| AgentError::Store("poisoned".into()))?.clone())
    }
    async fn upsert(&self, task: &ScheduledTask) -> Result<()> {
        let mut v = self.tasks.lock().map_err(|_| AgentError::Store("poisoned".into()))?;
        match v.iter_mut().find(|t| t.id == task.id) {
            Some(existing) => *existing = task.clone(),
            None => v.push(task.clone()),
        }
        Ok(())
    }
    async fn remove(&self, id: &str) -> Result<()> {
        self.tasks
            .lock()
            .map_err(|_| AgentError::Store("poisoned".into()))?
            .retain(|t| t.id != id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 1753401600 = 2025-07-25T00:00:00Z, a Friday. Saturday is the next day.
    const FRI_MIDNIGHT: u64 = 1_753_401_600;
    const SAT_MIDNIGHT: u64 = FRI_MIDNIGHT + DAY;

    #[test]
    fn daily_fires_today_when_the_time_is_still_ahead() {
        let next = next_run(Cadence::Daily { hour: 8, minute: 30 }, SAT_MIDNIGHT, 0);
        assert_eq!(next, SAT_MIDNIGHT + 8 * 3600 + 30 * 60);
    }

    #[test]
    fn daily_rolls_to_tomorrow_once_the_time_has_passed() {
        let after = SAT_MIDNIGHT + 9 * 3600; // 09:00, past an 08:30 slot
        let next = next_run(Cadence::Daily { hour: 8, minute: 30 }, after, 0);
        assert_eq!(next, SAT_MIDNIGHT + DAY + 8 * 3600 + 30 * 60);
    }

    #[test]
    fn weekdays_fires_the_same_day_when_it_is_a_weekday() {
        // Friday 00:00 → Friday 08:00. A weekday slot still ahead today must not roll forward.
        let next = next_run(Cadence::Weekdays { hour: 8, minute: 0 }, FRI_MIDNIGHT, 0);
        assert_eq!(next, FRI_MIDNIGHT + 8 * 3600);
    }

    #[test]
    fn weekdays_skips_the_weekend() {
        // Saturday → Monday, skipping Sunday entirely.
        let next = next_run(Cadence::Weekdays { hour: 8, minute: 0 }, SAT_MIDNIGHT, 0);
        assert_eq!(next, SAT_MIDNIGHT + 2 * DAY + 8 * 3600, "Saturday should skip to Monday");

        // And from Friday *after* the slot has passed, likewise Monday — not Saturday.
        let after = FRI_MIDNIGHT + 9 * 3600;
        let next = next_run(Cadence::Weekdays { hour: 8, minute: 0 }, after, 0);
        assert_eq!(next, FRI_MIDNIGHT + 3 * DAY + 8 * 3600, "Friday evening should skip to Monday");
    }

    #[test]
    fn the_offset_means_local_morning_not_utc_morning() {
        // WAT is UTC+1: 08:00 local is 07:00 UTC.
        let next = next_run(Cadence::Daily { hour: 8, minute: 0 }, SAT_MIDNIGHT, 3600);
        assert_eq!(next, SAT_MIDNIGHT + 7 * 3600);
    }

    #[test]
    fn a_one_off_is_spent_after_running_but_a_daily_reschedules() {
        let mut once = new_task("a", "x", Cadence::Once { at_unix: SAT_MIDNIGHT }, SAT_MIDNIGHT, 0);
        assert!(advance(&mut once, SAT_MIDNIGHT, 0), "a one-off must not repeat");

        let mut daily = new_task("b", "x", Cadence::Daily { hour: 8, minute: 0 }, SAT_MIDNIGHT, 0);
        let first = daily.next_run_unix;
        assert!(!advance(&mut daily, first, 0));
        assert_eq!(daily.next_run_unix, first + DAY);
        assert_eq!(daily.last_run_unix, Some(first));
    }

    #[test]
    fn only_enabled_and_due_tasks_fire() {
        let mut soon = new_task("a", "x", Cadence::Daily { hour: 8, minute: 0 }, SAT_MIDNIGHT, 0);
        let mut off = new_task("b", "y", Cadence::Daily { hour: 8, minute: 0 }, SAT_MIDNIGHT, 0);
        off.enabled = false;
        let later = new_task("c", "z", Cadence::Daily { hour: 23, minute: 0 }, SAT_MIDNIGHT, 0);
        soon.next_run_unix = SAT_MIDNIGHT; // due now
        off.next_run_unix = SAT_MIDNIGHT; // due, but disabled

        let firing = due(&[soon, off, later], SAT_MIDNIGHT);
        assert_eq!(firing.len(), 1);
        assert_eq!(firing[0].id, "a");
    }
}
