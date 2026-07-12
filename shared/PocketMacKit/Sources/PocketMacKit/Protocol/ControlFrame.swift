import Foundation

/// Opcodes for the ``FrameDomain/control`` domain. Stable numbering — the wire contract.
enum ControlOpcode: UInt8 {
    case hello = 0
    case ack = 1
    case error = 2
    case ping = 3
    case pong = 4
    case startVideo = 5
    case stopVideo = 6
}

/// Post-handshake application hello. Advertises peer name, app version, and capability flags
/// once the encrypted session is up. (Distinct from the cryptographic handshake, which happens
/// before any ``Frame`` flows.)
public struct HelloPayload: Sendable, Equatable {
    public let deviceName: String
    public let appVersion: String
    /// Reserved capability bitfield for additive feature negotiation.
    public let capabilities: UInt32

    public init(deviceName: String, appVersion: String, capabilities: UInt32 = 0) {
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.capabilities = capabilities
    }
}

/// Session-management messages that are neither input nor actions.
public enum ControlFrame: Sendable, Equatable {
    case hello(HelloPayload)
    /// Acknowledges an action or request by sequence number.
    case ack(seq: UInt32)
    case error(code: ProtocolErrorCode, message: String)
    /// Application-level liveness probe (paired with ``pong(nonce:)``).
    case ping(nonce: UInt32)
    case pong(nonce: UInt32)
    /// Phone → Mac: begin screen streaming at the given frame rate.
    case startVideo(fps: UInt8)
    /// Phone → Mac: stop screen streaming.
    case stopVideo

    var opcode: ControlOpcode {
        switch self {
        case .hello: .hello
        case .ack: .ack
        case .error: .error
        case .ping: .ping
        case .pong: .pong
        case .startVideo: .startVideo
        case .stopVideo: .stopVideo
        }
    }
}
