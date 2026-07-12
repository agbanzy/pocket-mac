import Foundation
import PocketMacKit

/// A tiny thread-safe boolean with an atomic compare-and-set, read/written from off-main `authorize`
/// closures. The CAS gives single-admission pairing with no TOCTOU window.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ value: Bool) { storage = value }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: Bool) { lock.lock(); storage = value; lock.unlock() }
    /// If the current value equals `expected`, set it to `new` and return true; else return false.
    func compareAndSet(expected: Bool, new: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if storage == expected { storage = new; return true }
        return false
    }
}

/// The menu-bar helper's coordinator: identity, peer store, input translator, action executor, the
/// Bonjour listener, the session accepter, and relay reachability — plus the menu-bar UI state.
///
/// Pairing is the security-critical gate (see the audit). It is: **time-bounded** (auto-closes),
/// **single-admission** (one peer per window, atomic across LAN + relay), **SAS-bound on both
/// transports**, and **uniformly closed** on success regardless of which transport paired. Revocation
/// terminates a peer's live session, not only its future handshakes.
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

    /// How long a pairing window stays open before auto-closing.
    static let pairingWindowTimeout: Duration = .seconds(120)

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
    var relayURL: URL?

    @ObservationIgnored private var currentPairingPayload: PairingPayload?
    @ObservationIgnored private var pairingGate: AtomicFlag?
    @ObservationIgnored private var pairingTimeoutTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        isAccessibilityTrusted = AccessibilityAuthorizer.isTrusted
        launchAtLogin = LoginItemManager.isEnabled
        parseRelayURL()
        startAdvertising()
        startRelayRespondersForPairedPeers()
        // Dev/CI only: open a pairing window at launch so the probe harness can pair unattended.
        // Gated out of release builds — an unbounded auto-pair window would be a real exposure.
        #if DEBUG
        if CommandLine.arguments.contains("--auto-pair") { startPairing() }
        #endif
    }

    /// The deployed zero-knowledge relay, so a double-clicked helper is reachable off-LAN by default.
    static let defaultRelayURL = "wss://165.227.155.134.sslip.io/ws"

    private func parseRelayURL() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--relay"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            relayURL = url // explicit override (used by the proof scripts)
        } else {
            relayURL = URL(string: Self.defaultRelayURL)
        }
    }

    func refreshAccessibility() { isAccessibilityTrusted = AccessibilityAuthorizer.isTrusted }

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

    /// On launch, keep the Mac relay-reachable for each already-paired peer. Reconnect handshakes use
    /// an empty prologue (Noise static-key auth) and admit only their own peer.
    private func startRelayRespondersForPairedPeers() {
        guard relayURL != nil else { return }
        for peer in peerStore.all() where !peer.isRevoked && peer.rendezvousToken != nil {
            startPerPeerRelayResponder(for: peer.peerID)
        }
    }

    private func startPerPeerRelayResponder(for peerID: PeerID) {
        guard let relayURL, let privateKeyData = try? identityStore.privateKey().rawRepresentation,
              let token = peerStore.peer(for: peerID)?.rendezvousToken else { return }
        let store = peerStore
        relayReachability.startResponder(
            id: peerID.fingerprint, relayURL: relayURL, token: token, prologue: Data(),
            privateKeyData: privateKeyData,
            authorize: { candidate, _ in candidate == peerID && store.isAuthorized(candidate) })
    }

    // MARK: Pairing

    func startPairing() {
        guard let identity = try? identityStore.loadOrCreateIdentity() else {
            lastError = "Could not load device identity"
            return
        }
        let payload = PairingPayload(
            macIdentity: identity, deviceName: deviceName,
            rendezvousToken: PairingCode.makeRendezvousToken(), sas: PairingCode.makeSAS())
        currentPairingPayload = payload
        activePairingURL = payload.urlString()
        activeSAS = payload.sas
        isPairing = true
        let gate = AtomicFlag(true)
        pairingGate = gate
        writePairingHandoff(payload.urlString())

        // Time-bound: auto-close the window so a captured QR can't be used later.
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pairingWindowTimeout)
            guard let self, self.isPairing else { return }
            self.stopPairing()
        }

        // Also wait for the phone on the relay (over-internet first-pairing). SAS-bound prologue, and
        // the SAME single-admission gate as LAN, so exactly one device pairs across both transports.
        if let relayURL, let privateKeyData = try? identityStore.privateKey().rawRepresentation {
            let authorize = makePairingAuthorize(gate: gate, token: payload.rendezvousToken)
            relayReachability.startResponder(
                id: "pairing", relayURL: relayURL, token: payload.rendezvousToken,
                prologue: Data(), privateKeyData: privateKeyData,
                continueWhile: { gate.value }, authorize: authorize)
        }
    }

    /// The shared pairing authorize used by BOTH LAN and relay. The atomic CAS admits at most one
    /// device across the whole window (no TOCTOU); the winner is recorded and the window is closed.
    private func makePairingAuthorize(gate: AtomicFlag, token: Data) -> @Sendable (PeerID, Data) -> Bool {
        let store = peerStore
        return { [weak self] peerID, publicKey in
            if gate.compareAndSet(expected: true, new: false) {
                store.upsert(PeerRecord(peerID: peerID, publicKey: publicKey, displayName: "iPhone", rendezvousToken: token))
                Task { @MainActor in self?.completePairing(peerID: peerID) }
                return true
            }
            return store.isAuthorized(peerID) // window already used → only an already-paired peer
        }
    }

    /// A device paired (on either transport). Close the window uniformly and stand up a persistent
    /// reconnect responder. Idempotent via `isPairing`.
    private func completePairing(peerID: PeerID) {
        guard isPairing else { return }
        isPairing = false
        activePairingURL = nil
        activeSAS = nil
        currentPairingPayload = nil
        pairingGate = nil
        pairingTimeoutTask?.cancel(); pairingTimeoutTask = nil
        writePairingHandoff(nil)
        connectedPeerCount += 1
        // The "pairing" relay responder self-terminates via continueWhile (gate is now consumed) after
        // its live session ends — never cancelled mid-session. Reconnects go to the per-peer responder.
        startPerPeerRelayResponder(for: peerID)
    }

    /// User cancelled, or the window timed out, with no device paired.
    func stopPairing() {
        guard isPairing else { return }
        isPairing = false
        activePairingURL = nil
        activeSAS = nil
        currentPairingPayload = nil
        pairingGate?.set(false); pairingGate = nil
        pairingTimeoutTask?.cancel(); pairingTimeoutTask = nil
        writePairingHandoff(nil)
        relayReachability.stop(id: "pairing") // safe: no admission happened, so no live session to kill
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

    /// Revoke a peer: block future handshakes AND cut off any session it currently holds.
    func revoke(_ peerID: PeerID) {
        peerStore.revoke(peerID)
        relayReachability.stop(id: peerID.fingerprint)
        Task { await accepter.terminate(peerID) }
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
        let store = peerStore
        let prologue: Data
        let authorize: @Sendable (PeerID, Data) -> Bool
        if isPairing, let gate = pairingGate, let payload = currentPairingPayload {
            prologue = Data() // empty prologue everywhere; pairing gated by the single-admission window
            authorize = makePairingAuthorize(gate: gate, token: payload.rendezvousToken)
        } else {
            prologue = Data()
            authorize = { peerID, _ in store.isAuthorized(peerID) }
        }
        _ = await accepter.accept(
            transport: transport, privateKeyData: privateKeyData, prologue: prologue,
            authorize: authorize, translator: translator, actions: actions)
        // Window closure on success is handled uniformly by the gate authorize → completePairing.
    }
}
