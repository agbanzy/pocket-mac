import Foundation
import CryptoKit
import Observation
import UIKit
import PocketMacKit

/// A frame consumer the input surfaces (trackpad, keyboard, deck) send to. Sending is fire-and-forget
/// and ordered; when there is no live session it is a silent no-op so the UI stays interactive.
@MainActor
protocol InputSink: AnyObject {
    func send(_ frame: Frame)
}

/// Owns the LAN connection lifecycle: builds the transport from a `DiscoveredService`, runs the Noise
/// IK handshake as **initiator** using the paired `PairingPayload`, brings up a `SecureSession`, and
/// exposes an ordered outbound queue plus observable link state and latency.
///
/// The outbound queue is an `AsyncStream`: `send(_:)` is a synchronous, thread-safe, FIFO-ordered
/// `yield` off the hot path (the trackpad's touch handler), while a single pump task drains it into
/// the `SecureSession` actor. That decouples the main thread from the actor and preserves input order.
@MainActor
@Observable
final class ConnectionController: InputSink {
    private(set) var state: ConnectionState = .idle
    /// Live round-trip latency in ms (from control ping/pong), or nil until the first sample.
    private(set) var latencyMS: Int?
    /// Which path the current session is running over (for the connection chip). Nil when not secured.
    private(set) var currentPath: ConnectionPath?

    /// The relay endpoint (`wss://…/ws`) for the away-from-home path. Nil until configured/deployed;
    /// the `.relay` path reports "No relay configured" while unset.
    var relayURL: URL?

    /// Phone-side state for the AI "Ask" agent running on the Mac (progress log, PIN prompt).
    let agent = AgentSession()

    private let identity: IdentityService

    private var session: SecureSession?
    private var outbound: AsyncStream<Frame>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingPings: [UInt32: Date] = [:]
    private var pingNonce: UInt32 = 0

    private var reassembler = VideoReassembler()
    /// Called on the main actor with each complete Annex-B video frame + the Mac's pixel size.
    var onVideoFrame: ((Data, Int, Int) -> Void)?

    init(identity: IdentityService) {
        self.identity = identity
    }

    // MARK: Lifecycle

    /// Establishes an encrypted session over the selected path using the paired Mac's payload.
    /// Tears down any prior session first. Never throws to the UI — failures land in `state`.
    func connect(path: PathSelector, payload: PairingPayload) async {
        disconnect()

        // Build the transport + handshake prologue for the chosen path. Everything below this is
        // identical for LAN and relay — that's the "keyed to identity, not path" invariant.
        let transport: any Transport
        let prologue: Data
        switch path {
        case .lan(let service):
            transport = NWConnectionTransport(connection: service.makeConnection())
            // Empty prologue everywhere so pairing and reconnect are consistent on both sides. Noise
            // static-key mutual auth carries the session; the pairing window is time-bounded +
            // single-admission, and the SAS is the visual confirmation.
            prologue = Data()
        case .relay(let rendezvousToken):
            guard let relayURL else {
                state = .offline("No relay configured")
                return
            }
            transport = RelayTransport(relayURL: relayURL, rendezvousToken: rendezvousToken)
            // Relay path: Noise static-key authentication carries it; SAS is a LAN-pairing defense.
            prologue = Data()
        }

        state = .connecting
        do {
            let localStatic = try identity.privateKey()
            let remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.macPublicKey)

            // Connect and handshake under one deadline. Both steps end in a socket read that the
            // other side may never satisfy, and without a limit the UI simply sat on "Connecting"
            // forever — which looks like a slow network but hides whatever actually failed. Failing
            // out puts a real reason on screen instead.
            let keys = try await withDeadline(Self.connectDeadline) {
                try await transport.start()
                // The app is the Noise initiator; it already knows the Mac's static key from pairing.
                return try await NoisePatternHandshake().performInitiator(
                    over: transport,
                    localStatic: localStatic,
                    remoteStatic: remoteStatic,
                    prologue: prologue
                )
            }

            let session = SecureSession(transport: transport, channel: AEADChannel(keys: keys))
            self.session = session
            startOutboundPump(session: session)
            startReceiveLoop(session: session)
            startHeartbeat()
            currentPath = path.connectionPath
            state = .secured

            // Post-handshake application hello so the Mac can show who connected.
            send(.control(.hello(HelloPayload(deviceName: Self.deviceName(),
                                              appVersion: PocketMac.version))))
        } catch {
            session = nil
            transport.close()   // don't leave a half-open socket behind on a failed attempt
            state = .offline(Self.describe(error))
        }
    }

    /// Ceiling on connect + handshake. See the note at the call site.
    private static let connectDeadline: Double = 10

    /// Tears the session down and returns to idle. Safe to call repeatedly.
    func disconnect() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        receiveTask?.cancel(); receiveTask = nil
        pumpTask?.cancel(); pumpTask = nil
        outbound?.finish(); outbound = nil
        let closing = session
        session = nil
        pendingPings.removeAll()
        latencyMS = nil
        currentPath = nil
        // Progress arrives as taskEvent frames, so losing the session means losing the only signal
        // that a task ever ended. Left as-is the phone showed "running" forever — Stop the only
        // button, no outcome, while the Mac carried on driving the cursor. The task may well still
        // be running over there; what is certainly false is that this phone knows anything about it.
        if agent.isRunning {
            agent.append(kind: .error, text: "Lost the connection while the task was running. "
                       + "It may still be going on your Mac — check History.")
        }
        agent.pendingPinReason = nil
        if closing != nil { Task { await closing?.close() } }
        if state.isSecured || state == .connecting { state = .idle }
    }

    // MARK: InputSink (hot path — synchronous, ordered)

    func send(_ frame: Frame) {
        outbound?.yield(frame)
    }

    // MARK: Pump / receive / heartbeat

    private func startOutboundPump(session: SecureSession) {
        // Unbounded so no input event (a click, a keyUp) is ever silently dropped. A production build
        // would coalesce `mouseMove` under sustained backpressure; Milestone 0 favors correctness.
        let (stream, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .unbounded)
        outbound = continuation
        pumpTask = Task { [weak self] in
            for await frame in stream {
                do {
                    try await session.send(frame)
                } catch {
                    self?.linkFailed(error) // pump task inherits @MainActor — same-actor call
                    break
                }
            }
        }
    }

    private func startReceiveLoop(session: SecureSession) {
        // Frame-level errors are ignored — a single undecodable frame must NOT drop a good session.
        // session.run() returns only when the transport itself dies; that is the real disconnect.
        receiveTask = Task { [weak self] in
            await session.run(onFrame: { [weak self] frame in
                await self?.handle(frame)
            }, onError: { _ in })
            await self?.linkFailed(TransportError.closed)
        }
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.sendPing() // heartbeat task inherits @MainActor — same-actor call
            }
        }
    }

    private func sendPing() {
        guard session != nil else { return }
        pingNonce &+= 1
        let nonce = pingNonce
        pendingPings[nonce] = Date()
        send(.control(.ping(nonce: nonce)))
    }

    private func handle(_ frame: Frame) {
        switch frame {
        case .control(.pong(let nonce)):
            if let sent = pendingPings.removeValue(forKey: nonce) {
                latencyMS = Int((Date().timeIntervalSince(sent) * 1000).rounded())
            }
        case .control(.ping(let nonce)):
            send(.control(.pong(nonce: nonce)))
        case .video(let chunk):
            if let frame = reassembler.accept(chunk) {
                onVideoFrame?(frame.annexB, frame.width, frame.height)
            }
        case .control(.scheduleList(let schedulesJson)):
            schedules = (try? JSONDecoder().decode([Schedule].self,
                                                   from: Data(schedulesJson.utf8))) ?? []
        case .control(.memoryList(let entriesJson)):
            memory = (try? JSONDecoder().decode([MemoryFact].self,
                                                from: Data(entriesJson.utf8))) ?? []
        case .control(.historyList(let tasksJson)):
            history = (try? JSONDecoder().decode([TaskSummary].self,
                                                 from: Data(tasksJson.utf8))) ?? []
        case .control(.providerList(let activeId, let availableJson)):
            activeProvider = activeId
            providers = (try? JSONDecoder().decode([ProviderOption].self,
                                                   from: Data(availableJson.utf8))) ?? []
        case .control(.taskEvent(let kind, let text)):
            agent.append(kind: kind, text: text)
        default:
            break
        }
    }

    /// Ask the Mac to start / stop streaming its screen.
    func startVideo(fps: UInt8 = 30) { send(.control(.startVideo(fps: fps))) }
    func stopVideo() { send(.control(.stopVideo)) }

    // MARK: AI task control

    /// Send a natural-language task to the Mac's Claude agent. `requirePin` gates sensitive steps.
    func runTask(_ prompt: String, requirePin: Bool) {
        agent.reset()
        agent.isRunning = true
        send(.control(.runTask(prompt: prompt, requirePin: requirePin)))
    }

    func stopTask() { send(.control(.stopTask)) }

    // MARK: Model provider

    /// Which providers this Mac can actually run, and which is active. Populated by the Mac's reply.
    private(set) var providers: [ProviderOption] = []
    private(set) var activeProvider: String = "claude"

    /// Ask the Mac what it can run. Answered with a `providerList` frame.
    func requestProviders() { send(.control(.getProviders)) }

    /// Choose the provider for future tasks. The Mac echoes the stored state back, so the UI shows
    /// what actually took effect rather than an optimistic guess.
    func setProvider(_ id: String, model: String = "") {
        send(.control(.setProvider(providerId: id, model: model)))
    }

    // MARK: Memory & history

    /// What the agent remembers, and what it has done. Both live on the Mac — the phone is a view.
    private(set) var memory: [MemoryFact] = []
    private(set) var history: [TaskSummary] = []

    func requestMemory() { send(.control(.getMemory)) }
    func requestHistory() { send(.control(.getHistory)) }

    /// Make the agent forget one fact. The Mac replies with the updated list, so the UI shows what
    /// actually happened rather than removing the row optimistically.
    func forgetMemory(_ key: String) { send(.control(.forgetMemory(key: key))) }

    // MARK: Schedules

    /// What the Mac runs on its own. The Mac owns the schedule; the phone is a view and an editor.
    private(set) var schedules: [Schedule] = []

    func requestSchedules() { send(.control(.getSchedules)) }

    /// Add or update. `next_run_unix == 0` asks the Mac to compute the first run in *its* timezone —
    /// the phone may be somewhere else, and a morning briefing should follow the machine.
    func setSchedule(_ s: Schedule) {
        guard let data = try? JSONEncoder().encode(s),
              let json = String(data: data, encoding: .utf8) else { return }
        send(.control(.setSchedule(scheduleJson: json)))
    }

    func removeSchedule(_ id: String) { send(.control(.removeSchedule(id: id))) }

    /// Answer a paused sensitive action. An empty string denies it.
    func sendPin(_ pin: String) {
        agent.pendingPinReason = nil
        send(.control(.pinResponse(pin: pin)))
    }

    private func linkFailed(_ error: Error) {
        let reason = Self.describe(error)
        disconnect()
        state = .offline(reason)
    }

    // MARK: Helpers

    private static func deviceName() -> String {
        UIDevice.current.name
    }

    private static func describe(_ error: Error) -> String {
        if let t = error as? TransportError {
            switch t {
            case .closed: return "Connection closed"
            case .notReady: return "Connection not ready"
            case .connectionFailed: return "Couldn't reach the Mac"
            case .recordTooLarge: return "Protocol error"
            }
        }
        if error is CryptoError {
            return "Handshake failed — check the pairing code"
        }
        return "Disconnected"
    }
}
