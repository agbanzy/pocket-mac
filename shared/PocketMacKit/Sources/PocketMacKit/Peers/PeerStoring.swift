import Foundation

/// Persists paired peers and answers the one authorization question the responder handshake asks:
/// *is this PeerID allowed to open a session right now?*
public protocol PeerStoring: Sendable {
    func peer(for id: PeerID) -> PeerRecord?
    func upsert(_ record: PeerRecord)
    func revoke(_ id: PeerID)
    func all() -> [PeerRecord]

    /// Known **and** not revoked. This is the predicate passed to
    /// ``SessionHandshaking/performResponder(over:localStatic:prologue:authorize:)``.
    func isAuthorized(_ id: PeerID) -> Bool
}

public extension PeerStoring {
    func isAuthorized(_ id: PeerID) -> Bool {
        guard let record = peer(for: id) else { return false }
        return !record.isRevoked
    }
}

/// Thread-safe in-memory store for tests, the probe, and previews. Apps back this with a persistent
/// store (Keychain/file/`UserDefaults`) that adopts the same protocol.
public final class InMemoryPeerStore: PeerStoring, @unchecked Sendable {
    private var records: [PeerID: PeerRecord] = [:]
    private let lock = NSLock()

    public init(_ initial: [PeerRecord] = []) {
        for record in initial { records[record.peerID] = record }
    }

    public func peer(for id: PeerID) -> PeerRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    public func upsert(_ record: PeerRecord) {
        lock.lock(); defer { lock.unlock() }
        records[record.peerID] = record
    }

    public func revoke(_ id: PeerID) {
        lock.lock(); defer { lock.unlock() }
        records[id]?.isRevoked = true
    }

    public func all() -> [PeerRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.values)
    }
}
