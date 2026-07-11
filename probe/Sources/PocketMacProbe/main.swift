import Foundation
import AppKit
import CoreGraphics
import CryptoKit
import Network
import PocketMacKit

// PocketMacProbe — the CI-grade end-to-end harness (verification Layer C).
//
// Discovers the running Mac helper over Bonjour, pairs with it as the Noise INITIATOR (exactly as
// the iPhone does), opens an encrypted session, drives the trackpad, and asserts the real cursor
// moved. Proves wire + crypto + transport + input-synthesis on one machine, no phone required.
//
// Usage:
//   PocketMacProbe [--assert] [--pairing-url <url>] [--pairing-file <path>]
// The pairing URL is what the helper shows when you click "Pair New Device" (it also writes it to
//   ~/Library/Application Support/PocketMac/pairing.url while pairing, which is the default source).

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func log(_ message: String) { print("[probe] \(message)") }

func readPairingURL(arguments: [String]) throws -> PairingPayload {
    if let idx = arguments.firstIndex(of: "--pairing-url"), idx + 1 < arguments.count {
        return try PairingPayload(urlString: arguments[idx + 1])
    }
    let defaultPath = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("PocketMac/pairing.url")
    let path: URL
    if let idx = arguments.firstIndex(of: "--pairing-file"), idx + 1 < arguments.count {
        path = URL(fileURLWithPath: arguments[idx + 1])
    } else {
        path = defaultPath
    }
    guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
        throw ProbeError("No pairing URL. Click “Pair New Device” in the helper, or pass --pairing-url. (looked in \(path.path))")
    }
    return try PairingPayload(urlString: contents.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Browses Bonjour for the helper, returning the first discovered service within `timeout`.
func discover(timeout: Duration) async -> DiscoveredService? {
    let browser = BonjourBrowsing()
    let stream = browser.start()
    defer { browser.stop() }
    return await withTaskGroup(of: DiscoveredService?.self) { group in
        group.addTask {
            for await update in stream {
                if let first = update.services.first { return first }
                if update.state == .permissionDenied { return nil }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Proves the remote path's transport interop: two `RelayTransport` peers rendezvous through a real
/// (locally-run) Go relay by a shared token, run the Noise handshake, and exchange encrypted frames
/// both ways — all through the relay, which sees only opaque ciphertext.
func runRelaySelftest(relayURL: URL) async throws {
    let token = PairingCode.makeRendezvousToken()
    let responderPrivate = try InMemoryIdentityStore().privateKey()
    let initiatorPrivate = try InMemoryIdentityStore().privateKey()
    let prologue = Data("relay-selftest".utf8)

    let responderTransport = RelayTransport(relayURL: relayURL, rendezvousToken: token)
    let initiatorTransport = RelayTransport(relayURL: relayURL, rendezvousToken: token)
    try await responderTransport.start()
    try await initiatorTransport.start()
    log("Both peers HELLO'd the relay with token \(token.hexEncodedString.prefix(8))… — running handshake")

    let handshake = NoisePatternHandshake()
    async let responderKeys = handshake.performResponder(
        over: responderTransport, localStatic: responderPrivate, prologue: prologue,
        authorize: { _, _ in true })
    let initiatorKeys = try await handshake.performInitiator(
        over: initiatorTransport, localStatic: initiatorPrivate,
        remoteStatic: responderPrivate.publicKey, prologue: prologue)
    let rKeys = try await responderKeys

    let initiatorSession = SecureSession(transport: initiatorTransport, channel: AEADChannel(keys: initiatorKeys))
    let responderSession = SecureSession(transport: responderTransport, channel: AEADChannel(keys: rKeys))

    try await initiatorSession.send(.input(.mouseMove(dx: 42, dy: -7)))
    let received = try await responderSession.receiveFrame()
    guard received == .input(.mouseMove(dx: 42, dy: -7)) else { throw ProbeError("frame mismatch over relay: \(received)") }

    try await responderSession.send(.control(.ack(seq: 99)))
    let ack = try await initiatorSession.receiveFrame()
    guard ack == .control(.ack(seq: 99)) else { throw ProbeError("ack mismatch over relay: \(ack)") }

    await initiatorSession.close()
    await responderSession.close()
    log("PASS — RelayTransport ↔ relay ↔ RelayTransport: Noise handshake + encrypted frames both directions.")
}

// MARK: - Run

let arguments = CommandLine.arguments
let shouldAssert = arguments.contains("--assert")

if let idx = arguments.firstIndex(of: "--relay-selftest"), idx + 1 < arguments.count {
    guard let url = URL(string: arguments[idx + 1]) else {
        log("FAIL — invalid relay URL"); exit(1)
    }
    do { try await runRelaySelftest(relayURL: url); exit(0) }
    catch { log("FAIL — \(error)"); exit(1) }
}

/// Drives the trackpad over an established session and reports whether the real cursor moved.
func driveAndReport(_ session: SecureSession, over path: String) async throws -> Never {
    CGWarpMouseCursorPosition(CGPoint(x: 500, y: 400))
    try await Task.sleep(for: .milliseconds(100))
    let before = NSEvent.mouseLocation
    log("Cursor before: (\(Int(before.x)), \(Int(before.y)))")

    let steps = 50
    let dxPerStep: Int16 = 5
    for _ in 0 ..< steps {
        try await session.send(.input(.mouseMove(dx: dxPerStep, dy: 0)))
        try await Task.sleep(for: .milliseconds(3))
    }
    try await Task.sleep(for: .milliseconds(250))
    let after = NSEvent.mouseLocation
    log("Cursor after:  (\(Int(after.x)), \(Int(after.y)))")

    let movedX = after.x - before.x
    log("Cursor Δx = \(Int(movedX)) (expected ≈ +\(steps * Int(dxPerStep)))")

    try await session.send(.input(.unicodeText("Pocket Mac probe ✅ ")))
    try await session.send(.action(ActionFrame(tileID: UUID(), action: .mediaKey(.playPause))))
    await session.close()

    if movedX > 100 {
        log("PASS — \(path): the helper moved the real cursor over an encrypted session."); exit(0)
    }
    let message = "Cursor did not move (Δx=\(Int(movedX))). The \(path) session worked end-to-end, but the helper likely lacks the Accessibility grant, so CGEventPost is a no-op."
    if shouldAssert { log("FAIL — \(message)"); exit(1) }
    log("WARN — \(message)"); exit(0)
}

do {
    let payload = try readPairingURL(arguments: arguments)
    log("Target: \(payload.deviceName) [\(payload.macPeerID.fingerprint)] SAS \(payload.sas)")
    let macPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.macPublicKey)
    let privateKey = try InMemoryIdentityStore().privateKey()
    let handshake = NoisePatternHandshake()

    if let idx = arguments.firstIndex(of: "--via-relay"), idx + 1 < arguments.count {
        guard let relayURL = URL(string: arguments[idx + 1]) else { throw ProbeError("invalid relay URL") }
        log("Connecting to the Mac THROUGH the relay at \(relayURL)…")
        let transport = RelayTransport(relayURL: relayURL, rendezvousToken: payload.rendezvousToken)
        try await transport.start()
        // The relay path uses an empty prologue: Noise static-key auth carries it; SAS is a
        // LAN-pairing defense confirmed out-of-band via the QR.
        let keys = try await handshake.performInitiator(
            over: transport, localStatic: privateKey, remoteStatic: macPublicKey, prologue: Data())
        log("Secure session established OVER THE RELAY with \(keys.peerID.fingerprint)")
        try await driveAndReport(SecureSession(transport: transport, channel: AEADChannel(keys: keys)), over: "relay")
    } else {
        log("Discovering helper over Bonjour…")
        guard let service = await discover(timeout: .seconds(6)) else {
            throw ProbeError("No _pocketmac._tcp helper found on the LAN (is the helper running + advertising?)")
        }
        log("Found “\(service.name)” — connecting…")
        let transport = NWConnectionTransport(connection: service.makeConnection())
        try await transport.start()
        let keys = try await handshake.performInitiator(
            over: transport, localStatic: privateKey, remoteStatic: macPublicKey, prologue: payload.pairingPrologue)
        log("Secure session established over LAN with \(keys.peerID.fingerprint)")
        try await driveAndReport(SecureSession(transport: transport, channel: AEADChannel(keys: keys)), over: "LAN")
    }
} catch {
    log("FAIL — \(error)")
    exit(1)
}
