import Foundation
import CryptoKit

/// A stable, opaque identifier for a paired device: `SHA256(rawIdentityPublicKey)`.
///
/// Short enough to display as a fingerprint, collision-resistant enough to key the peer store and
/// the relay routing header on.
public struct PeerID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Data // 32 bytes

    public init(rawValue: Data) {
        self.rawValue = rawValue
    }

    /// Derives the PeerID from a raw X25519 public key.
    public init(publicKey rawPublicKey: Data) {
        self.rawValue = Data(SHA256.hash(data: rawPublicKey))
    }

    /// A short hex fingerprint for display (first 8 bytes, grouped).
    public var fingerprint: String {
        rawValue.prefix(8).map { String(format: "%02X", $0) }.joined()
    }

    public var description: String { fingerprint }
}

/// A device's long-term cryptographic identity: an X25519 key-agreement keypair (design doc §6).
///
/// The private key is held only by ``IdentityStoring`` implementations (Keychain on device);
/// this value type carries the public half plus the derived ``PeerID``.
public struct DeviceIdentity: Sendable, Equatable {
    public let publicKey: Curve25519.KeyAgreement.PublicKey

    public init(publicKey: Curve25519.KeyAgreement.PublicKey) {
        self.publicKey = publicKey
    }

    /// The raw 32-byte public key.
    public var rawPublicKey: Data { publicKey.rawRepresentation }

    public var peerID: PeerID { PeerID(publicKey: rawPublicKey) }

    public static func == (lhs: DeviceIdentity, rhs: DeviceIdentity) -> Bool {
        lhs.rawPublicKey == rhs.rawPublicKey
    }
}
