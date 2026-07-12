import Foundation
import CryptoKit
import PocketMacKit

/// Accepts one inbound connection: throttles handshake attempts, runs the Noise responder handshake
/// (authorizing the peer), then drives a receive loop that turns decrypted frames into real input.
///
/// Tracks every live session by `PeerID` so ``terminate(_:)`` can cut off a peer's **active** session
/// immediately on revocation — not just its future handshakes.
actor SessionAccepter {
    private let handshake = NoisePatternHandshake()

    private var nextID = 0
    private var active: [Int: ActiveSession] = [:]

    /// Throttle on handshake ATTEMPTS (distinct from the post-auth input `RateLimiter`): a floor
    /// against SAS brute-force / connection floods. ~2 attempts/s sustained, burst 10 — far above any
    /// legitimate reconnect rate, far below a useful brute-force rate.
    private var handshakeLimiter = RateLimiter(capacity: 10, refillPerSecond: 2)

    private struct ActiveSession {
        let peerID: PeerID
        let task: Task<Void, Never>
        let transport: any Transport
    }

    /// LAN: establish and launch the session's receive loop detached; returns the peer id (or nil).
    func accept(
        transport: any Transport,
        privateKeyData: Data,
        prologue: Data,
        authorize: @escaping @Sendable (PeerID, Data) -> Bool,
        translator: CGEventTranslator,
        actions: ActionExecutor
    ) async -> PeerID? {
        guard handshakeLimiter.allow() else { transport.close(); return nil }
        guard let established = try? await establish(
            transport: transport, privateKeyData: privateKeyData, prologue: prologue,
            authorize: authorize, translator: translator, actions: actions) else {
            transport.close()
            return nil
        }
        let id = nextID; nextID += 1
        let task = Task.detached { [weak self] in
            await established.run()
            await self?.deregister(id)
        }
        active[id] = ActiveSession(peerID: established.peerID, task: task, transport: transport)
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
        guard handshakeLimiter.allow() else { transport.close(); return }
        guard let established = try? await establish(
            transport: transport, privateKeyData: privateKeyData, prologue: prologue,
            authorize: authorize, translator: translator, actions: actions) else {
            transport.close()
            return
        }
        let id = nextID; nextID += 1
        let task = Task { await established.run() }
        active[id] = ActiveSession(peerID: established.peerID, task: task, transport: transport)
        await task.value // inline — returns when the session ends or is terminated
        active[id] = nil
    }

    /// Immediately cut off every active session for `peerID` (revocation). Cancels the receive loop
    /// and closes the transport so an in-flight `receive()` unblocks at once.
    func terminate(_ peerID: PeerID) {
        for (id, session) in active where session.peerID == peerID {
            session.task.cancel()
            session.transport.close()
            active[id] = nil
        }
    }

    private func deregister(_ id: Int) {
        active[id] = nil
    }

    private struct Established {
        let peerID: PeerID
        let transport: any Transport
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
        return Established(peerID: keys.peerID, transport: transport,
                           run: { await session.run(onFrame: { frame in await runner.handle(frame) }) })
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

    private var streamer: ScreenStreamer?
    private var videoPump: Task<Void, Never>?

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
            switch control {
            case .ping(let nonce):
                try? await session.send(.control(.pong(nonce: nonce)))
            case .startVideo(let fps):
                await startStreaming(fps: Int(fps))
            case .stopVideo:
                stopStreaming()
            default:
                break
            }
        case .video:
            break // the Mac is the video SOURCE — it never receives video
        }
    }

    /// Starts screen capture and streams encoded frames to the phone. Chunks flow through a single
    /// serialized pump so they arrive in order; the newest are kept under backpressure.
    private func startStreaming(fps: Int) async {
        guard streamer == nil else { return }
        let session = self.session
        let counter = VideoFrameCounter()
        let (stream, continuation) = AsyncStream<VideoChunk>.makeStream(bufferingPolicy: .bufferingNewest(400))
        videoPump = Task { for await chunk in stream { try? await session.send(.video(chunk)) } }

        let streamer = ScreenStreamer(onEncodedFrame: { annexB, isKeyframe, width, height in
            let id = counter.next()
            for chunk in VideoChunk.chunk(frameID: id, annexB: annexB, isKeyframe: isKeyframe, width: width, height: height) {
                continuation.yield(chunk)
            }
        })
        do {
            try await streamer.start(fps: fps)
            self.streamer = streamer
        } catch {
            continuation.finish()
            videoPump?.cancel(); videoPump = nil
            try? await session.send(.control(.error(code: .internalError, message: "screen capture failed: \(error.localizedDescription)")))
        }
    }

    private func stopStreaming() {
        streamer?.stop(); streamer = nil
        videoPump?.cancel(); videoPump = nil
    }
}

/// Monotonic video frame id, incremented from the capture queue.
final class VideoFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt32 = 0
    func next() -> UInt32 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
}
