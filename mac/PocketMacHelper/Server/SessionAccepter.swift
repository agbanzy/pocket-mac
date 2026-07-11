import Foundation
import CryptoKit
import PocketMacKit

/// Runs the Noise responder handshake over an inbound connection (LAN or relay — any ``Transport``),
/// authorizes the peer, then drives a receive loop that turns decrypted frames into real input and
/// actions. Two entry points: `accept` (fire-and-forget, for the many concurrent LAN connections)
/// and `serve` (awaits the session's end, so the relay-reachability loop knows when to re-dial).
actor SessionAccepter {
    private let handshake = NoisePatternHandshake()

    /// LAN: establish and launch the session's receive loop detached; returns the peer id (or nil).
    func accept(
        transport: any Transport,
        privateKeyData: Data,
        prologue: Data,
        authorize: @escaping @Sendable (PeerID, Data) -> Bool,
        translator: CGEventTranslator,
        actions: ActionExecutor
    ) async -> PeerID? {
        guard let established = try? await establish(
            transport: transport, privateKeyData: privateKeyData, prologue: prologue,
            authorize: authorize, translator: translator, actions: actions) else {
            transport.close()
            return nil
        }
        Task.detached { await established.run() }
        return established.peerID
    }

    /// Relay: establish and run the session **inline**, returning only when it ends — so the caller
    /// can re-establish the rendezvous.
    func serve(
        transport: any Transport,
        privateKeyData: Data,
        prologue: Data,
        authorize: @escaping @Sendable (PeerID, Data) -> Bool,
        translator: CGEventTranslator,
        actions: ActionExecutor
    ) async {
        guard let established = try? await establish(
            transport: transport, privateKeyData: privateKeyData, prologue: prologue,
            authorize: authorize, translator: translator, actions: actions) else {
            transport.close()
            return
        }
        await established.run()
    }

    private struct Established {
        let peerID: PeerID
        let run: @Sendable () async -> Void
    }

    private func establish(
        transport: any Transport,
        privateKeyData: Data,
        prologue: Data,
        authorize: @escaping @Sendable (PeerID, Data) -> Bool,
        translator: CGEventTranslator,
        actions: ActionExecutor
    ) async throws -> Established {
        try await transport.start()
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        let keys = try await handshake.performResponder(
            over: transport, localStatic: privateKey, prologue: prologue, authorize: authorize)
        let session = SecureSession(transport: transport, channel: AEADChannel(keys: keys))
        let runner = SessionRunner(session: session, translator: translator, actions: actions)
        return Established(peerID: keys.peerID, run: { await session.run(onFrame: { await runner.handle($0) }) })
    }
}

/// Owns the per-session mutable state (the inbound rate limiter) and applies each decoded frame:
/// input → `CGEvent`, action → executed + acked, ping → pong.
private actor SessionRunner {
    private let session: SecureSession
    private let translator: CGEventTranslator
    private let actions: ActionExecutor
    /// Floor against a runaway/hostile client: ~600 input events/s burst, sustained 600/s.
    private var limiter = RateLimiter(capacity: 600, refillPerSecond: 600)

    init(session: SecureSession, translator: CGEventTranslator, actions: ActionExecutor) {
        self.session = session
        self.translator = translator
        self.actions = actions
    }

    func handle(_ frame: Frame) async {
        switch frame {
        case .input(let input):
            guard limiter.allow() else { return } // drop floods, keep the session alive
            translator.handle(input)
        case .action(let actionFrame):
            do {
                try await actions.execute(actionFrame.action)
                try? await session.send(.control(.ack(seq: 0)))
            } catch {
                try? await session.send(.control(.error(code: .internalError, message: String(describing: error))))
            }
        case .control(let control):
            if case .ping(let nonce) = control {
                try? await session.send(.control(.pong(nonce: nonce)))
            }
        }
    }
}
