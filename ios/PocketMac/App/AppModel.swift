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

    /// UserDefaults key for the configured relay endpoint (overrides the default below).
    static let relayURLDefaultsKey = "com.innoedge.pocketmac.relayURL"
    /// The deployed zero-knowledge relay (DigitalOcean, Frankfurt, managed TLS via Caddy + sslip.io).
    /// Used when no override is set in UserDefaults.
    static let defaultRelayURL = "wss://165.227.155.134.sslip.io/ws"

    /// The currently paired Mac (nil until first pairing). Persisted in `PeerVault`.
    private(set) var pairedMac: PairedMac?

    /// A pairing payload awaiting the user's SAS confirmation (from a QR scan or deep link).
    var pendingPairing: PairingPayload?

    /// Set when a `pocketmac://pair?…` deep link arrives, to raise the pairing sheet.
    var showPairingSheet = false

    /// Raised once, after the 5th successful session, to invite an open-source coffee tip.
    var showCoffeeSheet = false
    private static let useCountKey = "com.innoedge.pocketmac.useCount"
    private static let coffeeShownKey = "com.innoedge.pocketmac.coffeeShown"

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

        let relayURLString = UserDefaults.standard.string(forKey: Self.relayURLDefaultsKey) ?? Self.defaultRelayURL
        if let url = URL(string: relayURLString) {
            pathCoordinator.relayURL = url
        }
    }

    /// Called when the UI appears: if a Mac is already paired, start keeping the best-path session up.
    func start() {
        if let mac = pairedMac {
            pathCoordinator.enable(for: mac)
        }
    }

    /// Counts a successful session; on the 5th, raises the coffee sheet once (then never again).
    func recordUse() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.coffeeShownKey) else { return }
        let count = defaults.integer(forKey: Self.useCountKey) + 1
        defaults.set(count, forKey: Self.useCountKey)
        if count >= 5 {
            showCoffeeSheet = true
            defaults.set(true, forKey: Self.coffeeShownKey)
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
