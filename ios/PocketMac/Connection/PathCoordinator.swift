import Foundation
import Network
import Observation
import PocketMacKit

/// Keeps a live session to the paired Mac up over the **best available path**, transparently.
///
/// Prefers the LAN (lowest latency) whenever the Mac is discovered on it; otherwise falls back to the
/// relay. It re-selects when the discovered-service list changes (LAN comes/goes) and when the network
/// path changes (`NWPathMonitor` — WiFi↔cellular, connectivity up/down). Because the `SecureSession`
/// is keyed to device identity, a switch is just a re-handshake — invisible above the transport.
///
/// Note: the live WiFi↔cellular handoff is only fully exercisable on a physical device; in the
/// Simulator this drives auto-connect + LAN preference, which is what's testable there.
@MainActor
@Observable
final class PathCoordinator {
    /// The relay endpoint for the away path. Nil until configured/deployed → LAN-only (relay fallback
    /// is a no-op).
    var relayURL: URL? {
        didSet { connection.relayURL = relayURL }
    }

    private(set) var isEnabled = false

    private let connection: ConnectionController
    private let discovery: DiscoveryService
    private var monitor: NWPathMonitor?
    private var monitorTask: Task<Void, Never>?
    private var currentMac: PairedMac?
    private var reselecting = false

    init(connection: ConnectionController, discovery: DiscoveryService) {
        self.connection = connection
        self.discovery = discovery
    }

    /// Begin keeping a session to `mac` up over the best available path.
    func enable(for mac: PairedMac) {
        currentMac = mac
        isEnabled = true
        connection.relayURL = relayURL
        discovery.start()
        startPathMonitor()
        Task { await reselect() }
    }

    func disable() {
        isEnabled = false
        currentMac = nil
        monitorTask?.cancel(); monitorTask = nil
        monitor?.cancel(); monitor = nil
        discovery.stop()
        connection.disconnect()
    }

    /// Call when the discovered-services list changes (from the view observing `DiscoveryService`).
    func discoveryChanged() {
        Task { await reselect() }
    }

    /// Re-evaluate the best path and (re)connect if the current session isn't already on it.
    func reselect() async {
        guard isEnabled, let mac = currentMac, let payload = mac.payload, !reselecting else { return }
        reselecting = true
        defer { reselecting = false }

        let lanService = matchingLANService(for: mac)
        let preferred: ConnectionPath = lanService != nil ? .lan : .relay

        // If we're already secured on the preferred path, leave it alone (no churn).
        if connection.state.isSecured, connection.currentPath == preferred { return }

        if let service = lanService {
            await connection.connect(path: .lan(service), payload: payload)
            if connection.state.isSecured { return }
        }
        if relayURL != nil {
            await connection.connect(path: .relay(rendezvousToken: payload.rendezvousToken), payload: payload)
        }
    }

    /// Prefer a LAN service whose Bonjour name matches the paired Mac; else the first discovered.
    /// The handshake authenticates identity regardless, so a name collision can't connect the wrong Mac.
    private func matchingLANService(for mac: PairedMac) -> DiscoveredService? {
        discovery.services.first { $0.name == mac.displayName } ?? discovery.services.first
    }

    private func startPathMonitor() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        monitor.pathUpdateHandler = { _ in continuation.yield(()) }
        monitor.start(queue: DispatchQueue(label: "com.innoedge.pocketmac.pathmonitor"))
        monitorTask = Task { [weak self] in
            for await _ in stream {
                await self?.reselect()
            }
        }
    }
}
