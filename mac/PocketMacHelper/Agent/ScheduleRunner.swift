import Foundation
import UserNotifications
import os

/// Fires scheduled tasks while the helper is running — the "does things without being asked" half.
///
/// The schedule itself lives in `schedule.json`, written by the Rust core's format so both sides
/// read one file. This runner only decides *when*: it wakes every minute, asks which tasks are due,
/// and runs them through the same agent path a phone-issued task takes.
///
/// Deliberately conservative about two things:
///
/// * **One at a time.** Two agents driving the same cursor would fight, so a run in progress means
///   the next due task waits for the following tick rather than overlapping.
/// * **A missed window is skipped, not replayed.** If the Mac was asleep for six hours, firing six
///   backlogged briefings would be worse than none.
actor ScheduleRunner {
    private let log = Logger(subsystem: "com.innoedge.pocketmac", category: "schedule")
    private var timer: Task<Void, Never>?
    private var running = false

    static var scheduleURL: URL {
        AgentDataStore.root.appendingPathComponent("schedule.json")
    }

    struct Entry: Codable {
        var id: String
        var prompt: String
        var cadence: Cadence
        var enabled: Bool
        var next_run_unix: UInt64
        var last_run_unix: UInt64?
        var last_outcome: String?

        struct Cadence: Codable {
            var kind: String            // once | daily | weekdays | every_hours
            var at_unix: UInt64?
            var hour: UInt8?
            var minute: UInt8?
            var hours: UInt8?
        }
    }

    func start() {
        guard timer == nil else { return }
        requestNotificationPermission()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                // A minute is fine: schedules are minute-granular, and polling more often would
                // burn power for no user-visible benefit.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        log.info("schedule runner started")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() async {
        guard !running else { return }   // never overlap two agents on one cursor
        var entries = load()
        guard !entries.isEmpty else { return }

        let now = UInt64(Date().timeIntervalSince1970)
        guard let index = entries.firstIndex(where: { $0.enabled && $0.next_run_unix <= now }) else {
            return
        }

        running = true
        defer { running = false }

        var entry = entries[index]
        log.info("running scheduled task \(entry.id, privacy: .public)")

        let outcome = await runAgent(prompt: entry.prompt)

        entry.last_run_unix = now
        entry.last_outcome = String(outcome.prefix(180))
        if entry.cadence.kind == "once" {
            entries.remove(at: index)          // spent
        } else {
            entry.next_run_unix = Self.nextRun(entry.cadence, after: now)
            entries[index] = entry
        }
        save(entries)
        notify(title: entry.prompt, body: outcome)
    }

    /// Run the task on the shared Rust core, exactly as a phone-issued one.
    private func runAgent(prompt: String) async -> String {
        guard let key = AgentRunner.loadAPIKey() else {
            return "No API key configured."
        }
        // The emit callback runs on a Rust worker thread, so the outcome is captured through a
        // locked box rather than a captured var — Swift 6 rejects the latter, correctly: it is a
        // real data race between that thread and this one.
        let outcome = OutcomeBox()
        await RustAgentBridge.run(prompt: prompt, apiKey: key,
                                  persona: RustAgentBridge.persona) { kind, text in
            if kind == .done || kind == .error { outcome.set(text) }
        }
        return outcome.get()
    }

    /// Minimal thread-safe holder for the last meaningful line of a run.
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = "Finished."
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: Next-run arithmetic (mirrors agent-core's schedule module)

    static func nextRun(_ c: Entry.Cadence, after now: UInt64) -> UInt64 {
        let offset = Int64(TimeZone.current.secondsFromGMT(for: Date()))
        switch c.kind {
        case "every_hours":
            return now + UInt64(max(1, Int(c.hours ?? 1))) * 3600
        case "once":
            return c.at_unix ?? now
        default:
            let weekdaysOnly = (c.kind == "weekdays")
            let target = Int64(min(23, Int(c.hour ?? 8))) * 3600 + Int64(min(59, Int(c.minute ?? 0))) * 60
            let localNow = Int64(now) + offset
            let day = Int64((Double(localNow) / 86_400).rounded(.down))
            for step in 0..<15 {
                let d = day + Int64(step)
                let candidate = d * 86_400 + target
                if candidate <= localNow { continue }
                if weekdaysOnly {
                    let weekday = ((d % 7) + 11) % 7      // 0 = Sunday
                    if !(1...5).contains(weekday) { continue }
                }
                return UInt64(max(0, candidate - offset))
            }
            return now + 86_400
        }
    }

    // MARK: Storage

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: Self.scheduleURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    private func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.scheduleURL, options: .atomic)
    }

    /// JSON for the phone.
    static func listJSON() -> String {
        (try? String(contentsOf: scheduleURL, encoding: .utf8)) ?? "[]"
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(60))
        content.body = String(body.prefix(180))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
