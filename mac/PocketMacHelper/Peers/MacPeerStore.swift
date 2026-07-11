import Foundation
import PocketMacKit

/// File-backed ``PeerStoring`` for the Mac helper: persists paired phones as JSON under
/// Application Support so pairings and revocations survive relaunches.
final class MacPeerStore: PeerStoring, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cache: [PeerID: PeerRecord]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PocketMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("peers.json")
        self.cache = Self.load(from: url)
    }

    func peer(for id: PeerID) -> PeerRecord? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]
    }

    func upsert(_ record: PeerRecord) {
        lock.lock(); cache[record.peerID] = record; let snapshot = cache; lock.unlock()
        persist(snapshot)
    }

    func revoke(_ id: PeerID) {
        lock.lock(); cache[id]?.isRevoked = true; let snapshot = cache; lock.unlock()
        persist(snapshot)
    }

    func all() -> [PeerRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(cache.values)
    }

    // MARK: Persistence

    private static func load(from url: URL) -> [PeerID: PeerRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([PeerRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.peerID, $0) })
    }

    private func persist(_ snapshot: [PeerID: PeerRecord]) {
        guard let data = try? JSONEncoder().encode(Array(snapshot.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
