import Foundation

/// A remembered pairing. The responder (Mac) admits a session only from a peer whose record exists
/// and is not revoked (design doc §6, "accept only from paired peer IDs"). Revocation — the
/// remote-kill — is simply flipping `isRevoked` (or deleting the record).
public struct PeerRecord: Codable, Sendable, Equatable {
    public let peerID: PeerID
    /// Raw 32-byte X25519 static public key of the peer.
    public let publicKey: Data
    public var displayName: String
    public var pairedAt: Date
    public var isRevoked: Bool

    public init(peerID: PeerID, publicKey: Data, displayName: String, pairedAt: Date = Date(), isRevoked: Bool = false) {
        self.peerID = peerID
        self.publicKey = publicKey
        self.displayName = displayName
        self.pairedAt = pairedAt
        self.isRevoked = isRevoked
    }
}
