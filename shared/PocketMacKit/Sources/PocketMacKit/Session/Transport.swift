import Foundation

/// Errors thrown by a ``Transport``.
public enum TransportError: Error, Sendable, Equatable {
    case notReady
    case closed
    case connectionFailed(String)
    /// A length-prefixed record exceeded the sane ceiling (a memory-safety guard).
    case recordTooLarge(declared: Int, cap: Int)
}

/// A dumb, length-delimited byte pipe. The security layer (``SecureChannel``) and the framing
/// (``FrameCodec``) sit **above** this, so a transport never sees plaintext and is fully
/// interchangeable — the same ``SecureSession`` runs over LAN (``NWConnectionTransport``) or, later,
/// the relay (`RelayTransport`) without changing a line above it. That interchangeability is the
/// whole "keyed to identity, not path" invariant.
public protocol Transport: Sendable {
    /// Brings the transport up (e.g. waits for the connection to become ready).
    func start() async throws
    /// Sends one whole record. The transport is responsible for delimiting it on the wire.
    func send(_ record: Data) async throws
    /// Receives exactly one whole record.
    func receive() async throws -> Data
    /// Tears the transport down.
    func close()
}

/// The maximum size of a single record any transport will accept — bounds attacker-declared
/// allocations. Matches the relay's own 64 KB message cap; control frames are far smaller.
public let maxTransportRecordSize = 64 * 1024
