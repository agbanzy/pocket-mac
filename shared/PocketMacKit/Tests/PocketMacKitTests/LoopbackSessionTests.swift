import Foundation
import CryptoKit
import Testing
@testable import PocketMacKit

// MARK: - In-memory transport (deterministic, no network)

/// An async FIFO of records with back-pressure-free delivery and close semantics.
private actor DataChannel {
    private var buffer: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    func send(_ data: Data) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            buffer.append(data)
        }
    }

    func receive() async throws -> Data {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { throw TransportError.closed }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close() {
        closed = true
        for waiter in waiters { waiter.resume(throwing: TransportError.closed) }
        waiters.removeAll()
    }
}

/// A ``Transport`` backed by two ``DataChannel``s — one per direction.
private final class PipeTransport: Transport, @unchecked Sendable {
    private let inbound: DataChannel
    private let outbound: DataChannel
    init(inbound: DataChannel, outbound: DataChannel) {
        self.inbound = inbound
        self.outbound = outbound
    }
    func start() async throws {}
    func send(_ record: Data) async throws { await outbound.send(record) }
    func receive() async throws -> Data { try await inbound.receive() }
    func close() { let i = inbound, o = outbound; Task { await i.close(); await o.close() } }
}

private func makePipePair() -> (phone: PipeTransport, mac: PipeTransport) {
    let phoneToMac = DataChannel()
    let macToPhone = DataChannel()
    return (PipeTransport(inbound: macToPhone, outbound: phoneToMac),
            PipeTransport(inbound: phoneToMac, outbound: macToPhone))
}

// MARK: - Tests

@Suite("Handshake driver + SecureSession over a transport")
struct LoopbackSessionTests {
    typealias PrivKey = Curve25519.KeyAgreement.PrivateKey

    @Test("a paired phone and Mac handshake and then exchange encrypted frames both ways")
    func fullSession() async throws {
        let (phoneT, macT) = makePipePair()
        let phoneStatic = PrivKey(), macStatic = PrivKey()
        let phonePeerID = DeviceIdentity(publicKey: phoneStatic.publicKey).peerID
        let macPeerID = DeviceIdentity(publicKey: macStatic.publicKey).peerID

        // The Mac already trusts this phone (paired earlier).
        let peers = InMemoryPeerStore([
            PeerRecord(peerID: phonePeerID, publicKey: phoneStatic.publicKey.rawRepresentation, displayName: "iPhone")
        ])
        let handshake = NoisePatternHandshake()
        let prologue = Data("pair-sas-424242".utf8)

        async let macKeys = handshake.performResponder(
            over: macT, localStatic: macStatic, prologue: prologue,
            authorize: { peerID, _ in peers.isAuthorized(peerID) })
        let phoneKeys = try await handshake.performInitiator(
            over: phoneT, localStatic: phoneStatic, remoteStatic: macStatic.publicKey, prologue: prologue)
        let mk = try await macKeys

        #expect(phoneKeys.peerID == macPeerID)   // phone authenticated the Mac
        #expect(mk.peerID == phonePeerID)         // Mac authenticated the phone

        let phone = SecureSession(transport: phoneT, channel: AEADChannel(keys: phoneKeys))
        let mac = SecureSession(transport: macT, channel: AEADChannel(keys: mk))

        // phone → Mac: a trackpad frame
        try await phone.send(.input(.mouseMove(dx: 12, dy: -7)))
        #expect(try await mac.receiveFrame() == .input(.mouseMove(dx: 12, dy: -7)))

        // phone → Mac: an action; Mac → phone: its ack
        let tile = UUID()
        try await phone.send(.action(ActionFrame(tileID: tile, action: .launchApp(bundleID: "com.apple.Music"))))
        #expect(try await mac.receiveFrame() == .action(ActionFrame(tileID: tile, action: .launchApp(bundleID: "com.apple.Music"))))
        try await mac.send(.control(.ack(seq: 1)))
        #expect(try await phone.receiveFrame() == .control(.ack(seq: 1)))
    }

    @Test("an unpaired phone is refused: the Mac never sends message 2")
    func unauthorizedPeerRefused() async throws {
        let (phoneT, macT) = makePipePair()
        let phoneStatic = PrivKey(), macStatic = PrivKey()
        let peers = InMemoryPeerStore() // empty → phone unknown
        let handshake = NoisePatternHandshake()

        let macTask = Task { try await handshake.performResponder(
            over: macT, localStatic: macStatic, prologue: Data(),
            authorize: { peerID, _ in peers.isAuthorized(peerID) }) }

        // Drive only message 1 from the initiator so the responder can reach its authorize check.
        var initiator = NoiseHandshakeIK(role: .initiator, localStatic: phoneStatic,
                                         remoteStatic: macStatic.publicKey, prologue: Data())
        try await phoneT.send(try initiator.writeMessage1())

        await #expect(throws: CryptoError.self) { _ = try await macTask.value }
    }

    @Test("a revoked peer is refused")
    func revokedPeerRefused() async throws {
        let (phoneT, macT) = makePipePair()
        let phoneStatic = PrivKey(), macStatic = PrivKey()
        let phonePeerID = DeviceIdentity(publicKey: phoneStatic.publicKey).peerID
        let peers = InMemoryPeerStore([
            PeerRecord(peerID: phonePeerID, publicKey: phoneStatic.publicKey.rawRepresentation, displayName: "iPhone")
        ])
        peers.revoke(phonePeerID)

        let handshake = NoisePatternHandshake()
        let macTask = Task { try await handshake.performResponder(
            over: macT, localStatic: macStatic, prologue: Data(),
            authorize: { peerID, _ in peers.isAuthorized(peerID) }) }
        var initiator = NoiseHandshakeIK(role: .initiator, localStatic: phoneStatic,
                                         remoteStatic: macStatic.publicKey, prologue: Data())
        try await phoneT.send(try initiator.writeMessage1())

        await #expect(throws: CryptoError.self) { _ = try await macTask.value }
    }
}

@Suite("Rate limiter")
struct RateLimiterTests {
    @Test("allows a burst up to capacity then throttles")
    func burstThenThrottle() {
        var limiter = RateLimiter(capacity: 3, refillPerSecond: 1, now: 1000)
        let a = limiter.allow(now: 1000)
        let b = limiter.allow(now: 1000)
        let c = limiter.allow(now: 1000)
        let d = limiter.allow(now: 1000) // bucket empty
        #expect(a && b && c)
        #expect(!d)
    }

    @Test("refills over time")
    func refills() {
        var limiter = RateLimiter(capacity: 2, refillPerSecond: 10, now: 0)
        let a = limiter.allow(now: 0)
        let b = limiter.allow(now: 0)
        let empty = limiter.allow(now: 0)
        let refilled = limiter.allow(now: 0.2) // 0.2s * 10/s = 2 tokens back
        #expect(a && b)
        #expect(!empty)
        #expect(refilled)
    }
}

@Suite("Peer store")
struct PeerStoreTests {
    @Test("authorizes known, unrevoked peers only")
    func authorization() {
        let id = PeerID(publicKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let store = InMemoryPeerStore()
        #expect(!store.isAuthorized(id))                 // unknown
        store.upsert(PeerRecord(peerID: id, publicKey: id.rawValue, displayName: "x"))
        #expect(store.isAuthorized(id))                  // known
        store.revoke(id)
        #expect(!store.isAuthorized(id))                 // revoked
    }
}
