import Foundation
import OSLog

/// Watches the agent's data directory and pushes changes to connected phones.
///
/// The obvious way to keep the phone current would be to call ``BrainBroadcast`` from wherever the
/// Mac writes a memory or finishes a task — but most of those writes do not happen in Swift. The
/// Rust core owns `memory.json` and `tasks/` and writes them directly through its own store, so
/// there is no Swift call site to hook. Adding one would mean threading a callback down through the
/// FFI for every kind of write, and it would still miss anything a future backend wrote.
///
/// Observing the directory instead matches how the system is actually built: Rust owns the files,
/// Swift notices they changed. It also picks up edits made by anything else — a scheduled run, a
/// second process, a hand edit while debugging.
///
/// Writes are atomic (temp file + rename), which is what makes this reliable: a rename mutates the
/// *directory*, so one watch on the directory catches both a rewritten `memory.json` and a new file
/// under `tasks/`.
final class BrainWatcher: @unchecked Sendable {
    static let shared = BrainWatcher()

    private let log = Logger(subsystem: "com.innoedge.pocketmac", category: "brain-sync")
    private let queue = DispatchQueue(label: "com.innoedge.pocketmac.brainwatch")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private var coalesce: DispatchWorkItem?

    private init() {}

    func start() {
        queue.async { [self] in
            guard sources.isEmpty else { return }
            let root = AgentDataStore.root
            let tasks = root.appendingPathComponent("tasks", isDirectory: true)
            // Create both up front: you cannot watch a directory that does not exist yet, and on a
            // fresh install neither does until the first task runs.
            for dir in [root, tasks] {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                watch(dir)
            }
            log.info("watching agent data for changes")
        }
    }

    private func watch(_ directory: URL) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("could not watch \(directory.lastPathComponent, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleFlush() }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
        descriptors.append(fd)
    }

    /// A single logical change can produce several vnode events (temp file created, renamed over,
    /// directory touched). Coalesce them so one memory write does not fan out three snapshots to
    /// every connected phone.
    private func scheduleFlush() {
        coalesce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, BrainBroadcast.hasListeners else { return }
            BrainBroadcast.memoryChanged()
            BrainBroadcast.historyChanged()
            BrainBroadcast.schedulesChanged()
            self.log.debug("pushed agent state after a change on disk")
        }
        coalesce = work
        queue.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }
}
