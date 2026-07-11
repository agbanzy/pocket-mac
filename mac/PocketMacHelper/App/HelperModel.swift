import Foundation
import PocketMacKit

/// The menu-bar helper's coordinator: owns identity, the peer store, the input translator, the
/// action executor, the Bonjour listener, and the session accepter — and the small amount of UI
/// state the menu bar renders. `@MainActor` so UI reads/writes are safe; the network + input work
/// hops to the ``SessionAccepter`` actor.
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

    private var currentPairingPayload: PairingPayload?

    // MARK: Lifecycle

    func start() {
        isAccessibilityTrusted = AccessibilityAuthorizer.isTrusted
        launchAtLogin = LoginItemManager.isEnabled
        startAdvertising()
        // Scripted-proof affordance: `--auto-pair` opens the pairing window at launch so the
        // PocketMacProbe harness can pair without a human clicking the menu.
        if CommandLine.arguments.contains("--auto-pair") {
            startPairing()
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
        writePairingHandoff(payload.urlString())
    }

    func stopPairing() {
        isPairing = false
        activePairingURL = nil
        activeSAS = nil
        currentPairingPayload = nil
        writePairingHandoff(nil)
    }

    /// Mirrors the active pairing URL to a well-known file so the `PocketMacProbe` harness can pair
    /// without a camera. Written only during the pairing window; cleared when it ends.
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
    }

    var pairedDevices: [PeerRecord] {
        peerStore.all().sorted { $0.pairedAt > $1.pairedAt }
    }

    // MARK: Connection handling

    private func handle(_ transport: NWConnectionTransport) async {
        guard let privateKeyData = try? identityStore.privateKey().rawRepresentation else {
            transport.close()
            return
        }
        // Snapshot the pairing policy on the main actor before crossing into the accepter.
        let pairingPayload = isPairing ? currentPairingPayload : nil
        let prologue = pairingPayload?.pairingPrologue ?? Data()
        let store = peerStore
        let isPairingNow = (pairingPayload != nil)

        let authorize: @Sendable (PeerID, Data) -> Bool = { peerID, publicKey in
            if isPairingNow {
                // Pairing window: admit and remember the new phone.
                store.upsert(PeerRecord(peerID: peerID, publicKey: publicKey, displayName: "iPhone"))
                return true
            }
            // Normal: accept only an already-paired, non-revoked peer.
            return store.isAuthorized(peerID)
        }

        let peerID = await accepter.accept(
            transport: transport,
            privateKeyData: privateKeyData,
            prologue: prologue,
            authorize: authorize,
            translator: translator,
            actions: actions)

        if peerID != nil {
            connectedPeerCount += 1
            if isPairing { stopPairing() }
        }
    }
}
