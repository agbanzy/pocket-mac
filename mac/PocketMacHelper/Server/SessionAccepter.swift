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

    /// How long a peer gets to complete the Noise handshake before the connection is dropped.
    ///
    /// There was no limit at all. The responder's first act is to read message 1, so a peer that
    /// connected and then said nothing left that read outstanding forever, holding the socket open —
    /// one leaked connection per retry, and no error anywhere to say so. Ten seconds is far longer
    /// than a handshake needs on any path, including the relay.
    static let handshakeDeadline: Double = 10

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
        guard let established = try? await withDeadline(Self.handshakeDeadline, operation: {
            try await self.establish(
                transport: transport, privateKeyData: privateKeyData, prologue: prologue,
                authorize: authorize, translator: translator, actions: actions)
        }) else {
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
        guard let established = try? await withDeadline(Self.handshakeDeadline, operation: {
            try await self.establish(
                transport: transport, privateKeyData: privateKeyData, prologue: prologue,
                authorize: authorize, translator: translator, actions: actions)
        }) else {
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
        return Established(peerID: keys.peerID, transport: transport, run: {
            // Subscribe this session to unsolicited state pushes for as long as it lives, so memory,
            // history and schedules the Mac changes on its own reach the phone without it asking.
            let token = BrainBroadcast.register { frame in
                Task { try? await session.send(.control(frame)) }
            }
            defer { BrainBroadcast.deregister(token) }
            await session.run(onFrame: { frame in await runner.handle(frame) })
        })
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
    private var agent: AgentRunner?
    private var agentTask: Task<Void, Never>?

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
            case .runTask(let prompt, let requirePin):
                await runTask(prompt: prompt, requirePin: requirePin)
            case .stopTask:
                await agent?.stop()
            case .pinResponse(let pin):
                await agent?.providePin(pin)
            case .setProvider(let providerId, let model):
                ProviderStore.setActive(id: providerId, model: model)
                // Echo the new state back so the phone reflects what the Mac actually stored,
                // rather than optimistically showing a choice that may not have applied.
                try? await session.send(.control(.providerList(
                    activeId: ProviderStore.activeId(),
                    availableJson: ProviderStore.availableJSON())))
            case .getProviders:
                try? await session.send(.control(.providerList(
                    activeId: ProviderStore.activeId(),
                    availableJson: ProviderStore.availableJSON())))
            case .getMemory:
                try? await session.send(.control(.memoryList(
                    entriesJson: AgentDataStore.memoryJSON())))
            case .forgetMemory(let key):
                AgentDataStore.forget(key: key)
                // Reply with the new list so the phone reflects the Mac, not an optimistic removal.
                try? await session.send(.control(.memoryList(
                    entriesJson: AgentDataStore.memoryJSON())))
            case .getHistory:
                try? await session.send(.control(.historyList(
                    tasksJson: AgentDataStore.historyJSON())))
            case .getSchedules:
                try? await session.send(.control(.scheduleList(
                    schedulesJson: ScheduleRunner.listJSON())))
            case .setSchedule(let json):
                ScheduleRunner.upsert(json: json)
                try? await session.send(.control(.scheduleList(
                    schedulesJson: ScheduleRunner.listJSON())))
            case .removeSchedule(let id):
                ScheduleRunner.remove(id: id)
                try? await session.send(.control(.scheduleList(
                    schedulesJson: ScheduleRunner.listJSON())))
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

    /// Starts (or replaces) the on-Mac Claude agent for a phone-issued task, streaming its progress
    /// back as `.taskEvent` control frames.
    private func runTask(prompt: String, requirePin: Bool) async {
        agentTask?.cancel()
        await agent?.stop()
        RustAgentBridge.cancel()   // signal a previous Rust run; the next one resets the flag
        let session = self.session
        let emit: @Sendable (TaskEventKind, String) async -> Void = { kind, text in
            try? await session.send(.control(.taskEvent(kind: kind, text: text)))
        }
        agentTask = Task { [weak self] in
            // Prefer the shared Rust core — the same brain Windows and Android will run, and the
            // only path with MCP tools and durable task history. If it can't start (missing
            // capture permission, unwritable store), fall back to the in-process Swift loop so a
            // task never dies on plumbing.
            if let key = AgentRunner.loadAPIKey() {
                let rc = await RustAgentBridge.run(prompt: prompt, apiKey: key,
                                                   persona: RustAgentBridge.persona, emit: emit)
                guard RustAgentBridge.isStartupFailure(rc) else { return }
            }
            let runner = AgentRunner(emit: emit)
            await self?.adopt(runner)
            await runner.run(prompt: prompt, requirePin: requirePin)
        }
    }

    /// Retain the fallback runner so `stop()` can reach it.
    private func adopt(_ runner: AgentRunner) { agent = runner }
}

/// Monotonic video frame id, incremented from the capture queue.
final class VideoFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt32 = 0
    func next() -> UInt32 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
}
