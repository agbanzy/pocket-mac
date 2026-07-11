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

    private let identity: IdentityService

    private var session: SecureSession?
    private var outbound: AsyncStream<Frame>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingPings: [UInt32: Date] = [:]
    private var pingNonce: UInt32 = 0

    init(identity: IdentityService) {
        self.identity = identity
    }

    // MARK: Lifecycle

    /// Establishes an encrypted session over the selected path using the paired Mac's payload.
    /// Tears down any prior session first. Never throws to the UI — failures land in `state`.
    func connect(path: PathSelector, payload: PairingPayload) async {
        disconnect()

        let service: DiscoveredService
        switch path {
        case .lan(let s):
            service = s
        case .relay:
            state = .offline("Relay path not available yet")
            return
        }

        state = .connecting
        do {
            let transport = NWConnectionTransport(connection: service.makeConnection())
            try await transport.start()

            let localStatic = try identity.privateKey()
            let remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.macPublicKey)

            // The app is the Noise initiator; it already knows the Mac's static key from pairing.
            // The pairing SAS is bound into the prologue, so a wrong PIN fails the handshake.
            let keys = try await NoisePatternHandshake().performInitiator(
                over: transport,
                localStatic: localStatic,
                remoteStatic: remoteStatic,
                prologue: payload.pairingPrologue
            )

            let session = SecureSession(transport: transport, channel: AEADChannel(keys: keys))
            self.session = session
            startOutboundPump(session: session)
            startReceiveLoop(session: session)
            startHeartbeat()
            state = .secured

            // Post-handshake application hello so the Mac can show who connected.
            send(.control(.hello(HelloPayload(deviceName: Self.deviceName(),
                                              appVersion: PocketMac.version))))
        } catch {
            session = nil
            state = .offline(Self.describe(error))
        }
    }

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
        // The onFrame/onError closures run inside the session actor's domain, so each captures a
        // fresh weak self and hops back to the main actor.
        receiveTask = Task {
            await session.run(onFrame: { [weak self] frame in
                await self?.handle(frame)
            }, onError: { [weak self] error in
                await self?.linkFailed(error)
            })
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
        default:
            break
        }
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
