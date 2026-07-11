import Foundation

/// The three top-level frame domains. Encoded as the second byte of every record.
///
/// Domain + opcode together identify a frame. Unknown domains decode to
/// ``CodecError/unsupported(domain:opcode:)`` rather than crashing — forward compatibility
/// for peers speaking a newer additive protocol.
public enum FrameDomain: UInt8, Sendable, CaseIterable {
    case control = 0
    case input = 1
    case action = 2
}

/// A single decoded control-channel message. The root type exchanged over a ``SecureSession``.
public enum Frame: Sendable, Equatable {
    case control(ControlFrame)
    case input(InputFrame)
    case action(ActionFrame)

    /// The domain this frame belongs to. Used by the codec to emit the domain byte.
    public var domain: FrameDomain {
        switch self {
        case .control: .control
        case .input: .input
        case .action: .action
        }
    }
}

/// Structured error codes carried in a ``ControlFrame/error(code:message:)`` frame.
public enum ProtocolErrorCode: UInt8, Sendable, Equatable {
    case unknown = 0
    case unsupportedVersion = 1
    case notPaired = 2
    case rateLimited = 3
    case malformedFrame = 4
    case replayRejected = 5
    case internalError = 6
}
