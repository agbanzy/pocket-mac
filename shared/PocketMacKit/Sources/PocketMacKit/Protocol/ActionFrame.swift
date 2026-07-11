import Foundation

/// A system-defined media/hardware key. Realized on the Mac as an `NSEvent` subtype 8
/// (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`), sent as a down (`0xA`) then up (`0xB`).
public enum MediaKey: UInt8, Sendable, Equatable, CaseIterable {
    case playPause = 0
    case next = 1
    case previous = 2
    case volumeUp = 3
    case volumeDown = 4
    case mute = 5
    case brightnessUp = 6
    case brightnessDown = 7
}

/// A system control action realized via unprivileged paths (`pmset`, `screencapture`, etc.)
/// wherever possible, to avoid the per-target-app Automation (AppleEvents) permission prompt.
public enum SystemControl: UInt8, Sendable, Equatable, CaseIterable {
    case sleep = 0
    case lock = 1
    case screensaver = 2
    case missionControl = 3
    case showDesktop = 4
}

/// Opcodes for the ``FrameDomain/action`` domain. Each opcode is a ``TileAction`` kind.
enum ActionOpcode: UInt8 {
    case launchApp = 0
    case runShortcut = 1
    case mediaKey = 2
    case systemControl = 3
}

/// What a deck tile does when tapped.
public enum TileAction: Sendable, Equatable {
    /// Launch (or activate) an app by bundle identifier — `NSWorkspace.openApplication`.
    case launchApp(bundleID: String)
    /// Run a user macOS Shortcut by name — `shortcuts run "<name>"`.
    case runShortcut(name: String)
    case mediaKey(MediaKey)
    case systemControl(SystemControl)

    var opcode: ActionOpcode {
        switch self {
        case .launchApp: .launchApp
        case .runShortcut: .runShortcut
        case .mediaKey: .mediaKey
        case .systemControl: .systemControl
        }
    }
}

/// A request to run a deck tile. Request/acknowledge — the phone reflects success or failure
/// from the matching ``ControlFrame/ack(seq:)`` or ``ControlFrame/error(code:message:)``.
public struct ActionFrame: Sendable, Equatable {
    /// Stable identifier of the tile that fired (for correlating the ack on the phone).
    public let tileID: UUID
    public let action: TileAction

    public init(tileID: UUID, action: TileAction) {
        self.tileID = tileID
        self.action = action
    }
}
