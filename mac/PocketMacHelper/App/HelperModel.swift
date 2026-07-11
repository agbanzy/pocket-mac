import Foundation
import PocketMacKit

/// A tiny thread-safe boolean, read from off-main `authorize` closures.
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ value: Bool) { storage = value }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: Bool) { lock.lock(); storage = value; lock.unlock() }
}

/// The menu-bar helper's coordinator: owns identity, the peer store, the input translator, the
/// action executor, the Bonjour listener, the session accepter, and relay reachability — plus the
/// small UI state the menu bar renders. `@MainActor`; network + input work hops to actors.
@MainActor
@Observable
final class HelperModel {
    static let shared = HelperModel()

    private let identityStore = KeychainIdentityStore()
    let peerStore = MacPeerStore()
    private let translator = CGEventTranslator()
    private let actions = ActionExecutor()
    private let listener = ListenerService()
    private let accepter = SessionAccepter()
    @ObservationIgnored private lazy var relayReachability = RelayReachability(accepter: accepter, translator: translator, actions: actions)

    // UI state
    var isAccessibilityTrusted = false
    var isAdvertising = false
    var isPairing = false
    var launchAtLogin = false
    var activePairingURL: String?
    var activeSAS: String?
    var connectedPeerCount = 0
    var deviceName = Host.current().localizedName ?? "Mac"
    var lastError: String?
    /// The relay endpoint (from `--relay <wss-url>`); when set, the Mac stays reachable off-LAN.
    var relayURL: URL?

    private var currentPairingPayload: PairingPayload?
    private let pairingActive = AtomicBool(false)

    // MARK: Lifecycle

    func start() {
        isAccessibilityTrusted = AccessibilityAuthorizer.isTrusted
        launchAtLogin = LoginItemManager.isEnabled
        parseRelayURL()
        startAdvertising()
        startRelayRespondersForPairedPeers()
        if CommandLine.arguments.contains("--auto-pair") {
            startPairing()
        }
    }

    private func parseRelayURL() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--relay"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            relayURL = url
        }
    }

    func refreshAccessibility() {
        isAccessibilityTrusted = AccessibilityAuthorizer.isTrusted
    }

    func requestAccessibility() {
        _ = AccessibilityAuthorizer.promptIfNeeded()
        AccessibilityAuthorizer.openAccessibilitySettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do { try LoginItemManager.setEnabled(enabled); launchAtLogin = enabled }
        catch { lastError = String(describing: error) }
    }

    private func startAdvertising() {
        guard !isAdvertising else { return }
        do {
            try listener.start(instanceName: deviceName) { [weak self] transport in
                Task { await self?.handle(transport) }
            }
            isAdvertising = true
        } catch {
            lastError = String(describing: error)
        }
    }

    /// On launch, keep the Mac relay-reachable for every already-paired peer that has a token.
    /// The relay path relies on Noise static-key authentication (SAS is a LAN-pairing defense), so
    /// these responders use an empty prologue and admit only their own paired peer.
    private func startRelayRespondersForPairedPeers() {
        guard let relayURL, let privateKeyData = try? identityStore.privateKey().rawRepresentation else { return }
        let store = peerStore
        for peer in peerStore.all() where !peer.isRevoked {
            guard let token = peer.rendezvousToken else { continue }
            let expected = peer.peerID
            relayReachability.startResponder(
                id: expected.fingerprint, relayURL: relayURL, token: token, prologue: Data(),
                privateKeyData: privateKeyData,
                authorize: { candidate, _ in candidate == expected && store.isAuthorized(candidate) })
        }
    }

    // MARK: Pairing

    func startPairing() {
        guard let identity = try? identityStore.loadOrCreateIdentity() else {
            lastError = "Could not load device identity"
            return
        }
        let payload = PairingPayload(
            macIdentity: identity,
            deviceName: deviceName,
            rendezvousToken: PairingCode.makeRendezvousToken(),
            sas: PairingCode.makeSAS())
        currentPairingPayload = payload
        activePairingURL = payload.urlString()
        activeSAS = payload.sas
        isPairing = true
        pairingActive.set(true)
        writePairingHandoff(payload.urlString())

        // While pairing, also wait for the phone on the relay (for over-internet first-pairing).
        if let relayURL, let privateKeyData = try? identityStore.privateKey().rawRepresentation {
            let store = peerStore
            let flag = pairingActive
            let token = payload.rendezvousToken
            let authorize: @Sendable (PeerID, Data) -> Bool = { peerID, publicKey in
                if flag.value {
                    // Pairing window: admit + remember the phone, then graduate to only-paired.
                    store.upsert(PeerRecord(peerID: peerID, publicKey: publicKey, displayName: "iPhone", rendezvousToken: token))
                    flag.set(false)
                    return true
                }
                return store.isAuthorized(peerID)
            }
            relayReachability.startResponder(
                id: "pairing", relayURL: relayURL, token: token, prologue: Data(),
                privateKeyData: privateKeyData, authorize: authorize)
        }
    }

    /// User cancelled pairing before any phone paired.
    func stopPairing() {
        isPairing = false
        activePairingURL = nil
        activeSAS = nil
        currentPairingPayload = nil
        pairingActive.set(false)
        writePairingHandoff(nil)
        relayReachability.stop(id: "pairing")
    }

    /// Pairing succeeded — clear the UI but KEEP the relay responder (its flag has graduated to
    /// only-paired), so the Mac stays reachable for the new phone over the relay.
    private func finishPairingUI() {
        isPairing = false
        activePairingURL = nil
        activeSAS = nil
        currentPairingPayload = nil
        pairingActive.set(false)
        writePairingHandoff(nil)
    }

    private func writePairingHandoff(_ urlString: String?) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PocketMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("pairing.url")
        if let urlString {
            try? urlString.write(to: file, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Peers

    func revoke(_ peerID: PeerID) {
        peerStore.revoke(peerID)
        relayReachability.stop(id: peerID.fingerprint)
    }

    var pairedDevices: [PeerRecord] {
        peerStore.all().sorted { $0.pairedAt > $1.pairedAt }
    }

    // MARK: LAN connection handling

    private func handle(_ transport: NWConnectionTransport) async {
        guard let privateKeyData = try? identityStore.privateKey().rawRepresentation else {
            transport.close()
            return
        }
        let pairingPayload = isPairing ? currentPairingPayload : nil
        let prologue = pairingPayload?.pairingPrologue ?? Data() // LAN pairing keeps SAS binding
        let store = peerStore
        let flag = pairingActive
        let token = pairingPayload?.rendezvousToken
        let isPairingNow = (pairingPayload != nil)

        let authorize: @Sendable (PeerID, Data) -> Bool = { peerID, publicKey in
            if isPairingNow {
                store.upsert(PeerRecord(peerID: peerID, publicKey: publicKey, displayName: "iPhone", rendezvousToken: token))
                flag.set(false)
                return true
            }
            return store.isAuthorized(peerID)
        }

        let peerID = await accepter.accept(
            transport: transport, privateKeyData: privateKeyData, prologue: prologue,
            authorize: authorize, translator: translator, actions: actions)

        if peerID != nil {
            connectedPeerCount += 1
            if isPairing { finishPairingUI() }
        }
    }
}
