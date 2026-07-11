import Foundation

/// The security seam between the codec and the transport. Seals outgoing plaintext records and
/// opens incoming ones. Kept a protocol so the AEAD record layer (``AEADChannel``) can be swapped
/// for a `TLSChannel` contingency without touching ``SecureSession``.
public protocol SecureChannel: Sendable {
    /// The authenticated identity of the peer on the other end of this channel.
    var peerID: PeerID { get }

    /// Seals a plaintext frame record into a wire record (counter ‖ ciphertext ‖ tag).
    mutating func seal(_ plaintext: Data) throws -> Data

    /// Opens a wire record back into the plaintext frame record, rejecting replays and tampering.
    mutating func open(_ record: Data) throws -> Data
}
