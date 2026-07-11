import Foundation

/// Generates the short-lived values minted when the Mac starts a pairing session.
public enum PairingCode {
    /// A fresh 6-digit short authentication string (`"000000"`–`"999999"`).
    public static func makeSAS() -> String {
        let n = UInt32.random(in: 0 ..< 1_000_000)
        return String(format: "%06u", n)
    }

    /// A fresh 128-bit relay rendezvous token — random routing id, never a cryptographic key.
    public static func makeRendezvousToken() -> Data {
        Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })
    }
}
