import Foundation
import CryptoKit
import PocketMacKit

/// Accepts one inbound connection: runs the Noise responder handshake (authorizing the peer), then
/// spins up a long-lived receive loop that turns decrypted frames into real input and actions.
actor SessionAccepter {
    private let handshake = NoisePatternHandshake()

    /// Performs the handshake and, on success, launches the session's receive loop as a detached
    /// task. Returns the authenticated peer id, or nil if the handshake/authorization failed.
    func accept(
        transport: NWConnectionTransport,
        privateKeyData: Data,
        prologue: Data,
        authorize: @escaping @Sendable (PeerID, Data) -> Bool,
        translator: CGEventTranslator,
        actions: ActionExecutor
    ) async -> PeerID? {
        do {
            try await transport.start()
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
            let keys = try await handshake.performResponder(
                over: transport, localStatic: privateKey, prologue: prologue, authorize: authorize)

            let session = SecureSession(transport: transport, channel: AEADChannel(keys: keys))
            let runner = SessionRunner(session: session, translator: translator, actions: actions)
            Task.detached {
                await session.run(onFrame: { frame in await runner.handle(frame) })
            }
            return keys.peerID
        } catch {
            transport.close()
            return nil
        }
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
