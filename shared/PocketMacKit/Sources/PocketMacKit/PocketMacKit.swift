import Foundation

/// Package-wide version + wire-compatibility constants.
///
/// `wireProtocolVersion` is the single source of truth for on-the-wire compatibility.
/// It is emitted as the first byte of every ``FrameCodec`` record and checked on decode.
/// Bump it only for breaking changes to the frame layout; additive opcodes do not require a bump.
public enum PocketMac {
    /// Human-facing product version.
    public static let version = "1.0.0"

    /// On-the-wire protocol version. First byte of every encoded frame.
    public static let wireProtocolVersion: UInt8 = 1

    /// Bonjour service type advertised by the Mac helper and browsed by the iOS app.
    public static let bonjourServiceType = "_pocketmac._tcp"

    /// Bonjour domain (unicast, `.local`).
    public static let bonjourDomain = "local."
}
