import Foundation

/// Errors thrown while encoding or decoding a ``Frame``.
///
/// Every decode failure is a typed throw — the codec never traps on malformed input, so a
/// hostile or buggy peer cannot crash the process by sending garbage.
public enum CodecError: Error, Equatable, Sendable {
    /// The buffer ended before a field could be fully read.
    case truncated(needed: Int, available: Int)
    /// A record declared a protocol version this build does not speak.
    case unsupportedVersion(UInt8)
    /// Known version, but an unrecognized domain/opcode pair (a newer additive frame).
    case unsupported(domain: UInt8, opcode: UInt8)
    /// The declared payload length exceeds the sane per-frame cap (a DoS guard).
    case overlongLength(declared: Int, cap: Int)
    /// A length-prefixed string was not valid UTF-8.
    case invalidString
    /// An enum-coded field held a value outside its known cases.
    case invalidEnum(field: String, value: UInt64)
}
