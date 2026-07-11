import Foundation
import Observation
import PocketMacKit

/// The root app state: this device's identity, the paired-Mac record, the discovery browser, the
/// connection controller, and the deck. Owns deep-link and pairing routing. `@MainActor` because all
/// of its state feeds SwiftUI directly.
@MainActor
@Observable
final class AppModel {
    let identity: IdentityService
    let connection: ConnectionController
    let discovery: DiscoveryService
    let pathCoordinator: PathCoordinator
    let deck: DeckStore
    private let vault: PeerVault

    /// UserDefaults key for the configured relay endpoint (set once the relay is deployed).
    static let relayURLDefaultsKey = "com.innoedge.pocketmac.relayURL"

    /// The currently paired Mac (nil until first pairing). Persisted in `PeerVault`.
    private(set) var pairedMac: PairedMac?

    /// A pairing payload awaiting the user's SAS confirmation (from a QR scan or deep link).
    var pendingPairing: PairingPayload?

    /// Set when a `pocketmac://pair?…` deep link arrives, to raise the pairing sheet.
    var showPairingSheet = false

    init() {
        let identity = IdentityService()
        self.identity = identity
        let connection = ConnectionController(identity: identity)
        let discovery = DiscoveryService()
        self.connection = connection
        self.discovery = discovery
        self.pathCoordinator = PathCoordinator(connection: connection, discovery: discovery)
        self.deck = DeckStore()
        let vault = PeerVault()
        self.vault = vault
        self.pairedMac = vault.load()

        if let string = UserDefaults.standard.string(forKey: Self.relayURLDefaultsKey),
           let url = URL(string: string) {
            pathCoordinator.relayURL = url
        }
    }

    /// Called when the UI appears: if a Mac is already paired, start keeping the best-path session up.
    func start() {
        if let mac = pairedMac {
            pathCoordinator.enable(for: mac)
        }
    }

    /// This phone's identity fingerprint, shown during pairing.
    var deviceFingerprint: String { identity.peerFingerprint }

    /// The kit `PeerRecord` for the paired Mac, as the app-model contract calls for.
    var pairedPeerRecord: PeerRecord? { pairedMac?.peerRecord }

    // MARK: Deep link

    /// Handles `pocketmac://pair?…` deep links by decoding the payload and surfacing the SAS
    /// confirmation. Invalid URLs are ignored, never crash.
    func handleIncoming(url: URL) {
        guard let payload = try? PairingPayload(url: url) else { return }
        pendingPairing = payload
        showPairingSheet = true
    }

    // MARK: Pairing

    /// Accepts a scanned/entered payload for SAS confirmation.
    func stagePairing(_ payload: PairingPayload) {
        pendingPairing = payload
    }

    /// Confirms the SAS match and persists the Mac as the paired peer.
    func confirmPairing(_ payload: PairingPayload) {
        let mac = PairedMac(payload: payload)
        vault.save(mac)
        pairedMac = mac
        pendingPairing = nil
        showPairingSheet = false
        pathCoordinator.enable(for: mac) // auto-connect over the best available path
    }

    func cancelPairing() {
        pendingPairing = nil
    }

    func unpair() {
        pathCoordinator.disable()
        vault.clear()
        pairedMac = nil
    }

    // MARK: Connect

    /// Connects to the paired Mac over a discovered LAN service.
    func connect(to service: DiscoveredService) async {
        guard let payload = pairedMac?.payload else { return }
        await connection.connect(path: .lan(service), payload: payload)
    }
}
