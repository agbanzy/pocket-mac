import Foundation

/// Errors thrown by the crypto core (identity, pairing, record layer, handshake).
public enum CryptoError: Error, Equatable, Sendable {
    /// AEAD authentication failed on open — wrong key, tampered ciphertext, or tampered tag.
    case authenticationFailed
    /// A record's counter did not advance (replay or reorder) — see ``ReplayWindow``.
    case replayDetected(counter: UInt64)
    /// The per-direction nonce counter is exhausted; the session must be torn down, never reused.
    case nonceExhausted
    /// A sealed record was too short to contain the counter + tag.
    case malformedRecord
    /// A handshake message was malformed or arrived out of sequence.
    case handshakeFailed(reason: String)
    /// A key or public-key blob was not the expected length.
    case invalidKeyLength
    /// The pairing PIN/SAS did not match — channel binding rejected the peer.
    case pairingMismatch
}
