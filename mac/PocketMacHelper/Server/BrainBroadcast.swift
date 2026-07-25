import Foundation
import OSLog
import PocketMacKit

/// Pushes state the Mac changed on its own out to every connected phone.
///
/// Everything about memory, history and schedules used to be request/response: the phone asked, the
/// Mac answered, and that was the only time anything moved. So the moment the Mac changed something
/// by itself — the agent remembered a fact, a task finished, a scheduled briefing ran — the phone
/// kept showing whatever it had last fetched, with no indication it was stale. Leaving the sheet and
/// coming back was the only way to see the truth.
///
/// The fix does not need a new protocol. `memoryList`, `historyList` and `scheduleList` already
/// carry a complete snapshot, and the phone's frame handling does not care whether a frame it
/// receives was solicited. So the Mac just sends the same frames again, unprompted, whenever the
/// underlying data changes.
///
/// Sending a whole snapshot rather than a delta is deliberate: these lists are small and bounded,
/// and a snapshot cannot drift out of sync the way a missed delta can.
enum BrainBroadcast {
    private static let log = Logger(subsystem: "com.innoedge.pocketmac", category: "brain-sync")

    /// A live session's sender. Sessions come and go on their own tasks, so this is a plain locked
    /// dictionary rather than an actor — registration happens on the session's task, and pushes
    /// happen on whichever thread mutated the data, neither of which should have to await the other.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sinks: [Int: @Sendable (ControlFrame) -> Void] = [:]
    nonisolated(unsafe) private static var nextID = 0

    /// Register a live session. Returns a token to pass to ``deregister(_:)`` when it ends.
    static func register(_ sink: @escaping @Sendable (ControlFrame) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        sinks[id] = sink
        return id
    }

    static func deregister(_ token: Int) {
        lock.lock(); defer { lock.unlock() }
        sinks[token] = nil
    }

    /// Fan a frame out to every connected phone. Fire-and-forget: a push is a courtesy, and a phone
    /// that misses one still gets the truth the next time it asks.
    static func push(_ frame: ControlFrame) {
        lock.lock(); let targets = Array(sinks.values); lock.unlock()
        guard !targets.isEmpty else { return }
        for send in targets { send(frame) }
    }

    // MARK: What changed

    /// The agent remembered or forgot something.
    static func memoryChanged() {
        push(.memoryList(entriesJson: AgentDataStore.memoryJSON()))
    }

    /// A task started, finished, or failed.
    static func historyChanged() {
        push(.historyList(tasksJson: AgentDataStore.historyJSON()))
    }

    /// A schedule was added, removed, or ran (which rewrites its next-run and last-outcome).
    static func schedulesChanged() {
        push(.scheduleList(schedulesJson: ScheduleRunner.listJSON()))
    }
}
