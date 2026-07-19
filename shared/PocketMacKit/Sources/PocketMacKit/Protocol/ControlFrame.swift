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
    // AI task control (phone drives an on-Mac Claude agent).
    case runTask = 7
    case taskEvent = 8
    case stopTask = 9
    case pinResponse = 10
}

/// Progress events streamed Mac → phone while an AI task runs. Text-only (the payload cap is 64 KB
/// and the live screen is already available over the video channel), so the phone renders a log.
public enum TaskEventKind: UInt8, Sendable, Equatable {
    case started = 0    // the agent accepted the task and began
    case thinking = 1   // model narration / reasoning summary
    case action = 2     // an action was executed on the Mac (text describes it)
    case needsPin = 3   // a sensitive action is paused awaiting the PIN
    case done = 4       // task complete (text is the final summary)
    case error = 5      // task failed / aborted (text is the reason)
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
    /// Phone → Mac: run a natural-language task via the on-Mac Claude agent. `requirePin` gates
    /// sensitive actions behind the PIN (the Express vs PIN model).
    case runTask(prompt: String, requirePin: Bool)
    /// Mac → phone: a progress event while a task runs.
    case taskEvent(kind: TaskEventKind, text: String)
    /// Phone → Mac: abort the running task.
    case stopTask
    /// Phone → Mac: the PIN the user entered to allow a paused sensitive action (empty = deny).
    case pinResponse(pin: String)

    var opcode: ControlOpcode {
        switch self {
        case .hello: .hello
        case .ack: .ack
        case .error: .error
        case .ping: .ping
        case .pong: .pong
        case .startVideo: .startVideo
        case .stopVideo: .stopVideo
        case .runTask: .runTask
        case .taskEvent: .taskEvent
        case .stopTask: .stopTask
        case .pinResponse: .pinResponse
        }
    }
}
