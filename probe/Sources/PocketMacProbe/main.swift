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

// MARK: - Run

let arguments = CommandLine.arguments
let shouldAssert = arguments.contains("--assert")

do {
    let payload = try readPairingURL(arguments: arguments)
    log("Pairing target: \(payload.deviceName) [\(payload.macPeerID.fingerprint)] SAS \(payload.sas)")

    log("Discovering helper over Bonjour…")
    guard let service = await discover(timeout: .seconds(6)) else {
        throw ProbeError("No _pocketmac._tcp helper found on the LAN (is the helper running + advertising?)")
    }
    log("Found “\(service.name)” — connecting…")

    let transport = NWConnectionTransport(connection: service.makeConnection())
    try await transport.start()

    let identity = InMemoryIdentityStore()
    let privateKey = try identity.privateKey()
    let macPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.macPublicKey)

    log("Running Noise IK handshake (initiator)…")
    let keys = try await NoisePatternHandshake().performInitiator(
        over: transport, localStatic: privateKey,
        remoteStatic: macPublicKey, prologue: payload.pairingPrologue)
    log("Secure session established with \(keys.peerID.fingerprint)")

    let session = SecureSession(transport: transport, channel: AEADChannel(keys: keys))

    // Drive the trackpad: center the cursor, then push it clearly to the right.
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

    // Fire a couple of frames for manual observation, then a benign action.
    try await session.send(.input(.unicodeText("Pocket Mac probe ✅ ")))
    try await session.send(.action(ActionFrame(tileID: UUID(), action: .mediaKey(.playPause))))

    await session.close()

    if movedX > 100 {
        log("PASS — the helper moved the real cursor over an encrypted session.")
        exit(0)
    } else {
        let message = "Cursor did not move as expected (Δx=\(Int(movedX))). The session worked, but the helper likely lacks the Accessibility grant, so CGEventPost is a no-op. Grant it in System Settings → Privacy & Security → Accessibility."
        if shouldAssert {
            throw ProbeError(message)
        } else {
            log("WARN — \(message)")
            exit(0)
        }
    }
} catch {
    log("FAIL — \(error)")
    exit(1)
}
