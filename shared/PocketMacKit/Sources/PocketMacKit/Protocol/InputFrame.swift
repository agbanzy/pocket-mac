import Foundation

/// A physical mouse button.
public enum MouseButton: UInt8, Sendable, Equatable, CaseIterable {
    case left = 0
    case right = 1
    case middle = 2
}

/// Keyboard modifier flags. Mirrors the subset of `CGEventFlags` the helper applies.
///
/// Bit layout is part of the wire contract — do not reorder existing cases.
public struct ModifierFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = ModifierFlags(rawValue: 1 << 0)
    public static let control = ModifierFlags(rawValue: 1 << 1)
    public static let option = ModifierFlags(rawValue: 1 << 2)
    public static let command = ModifierFlags(rawValue: 1 << 3)
    public static let function = ModifierFlags(rawValue: 1 << 4)
    public static let capsLock = ModifierFlags(rawValue: 1 << 5)
}

/// Opcodes for the ``FrameDomain/input`` domain. Stable numbering — the wire contract.
enum InputOpcode: UInt8 {
    case mouseMove = 0
    case mouseDown = 1
    case mouseUp = 2
    case mouseClick = 3
    case scroll = 4
    case keyDown = 5
    case keyUp = 6
    case unicodeText = 7
    case setModifiers = 8
}

/// A real-time input event. High-frequency, fire-and-forget — the latency-critical hot path.
///
/// Pointer motion and scrolling carry **relative** deltas (never absolute coordinates), so the
/// helper applies its own pointer acceleration and the phone never needs to know the Mac's
/// screen geometry. `mouseMove` is the frequency-dominant frame and encodes to a tight 4-byte payload.
public enum InputFrame: Sendable, Equatable {
    /// Relative pointer motion, in points. Signed.
    case mouseMove(dx: Int16, dy: Int16)
    case mouseDown(MouseButton)
    case mouseUp(MouseButton)
    /// A synthesized click. `count == 2` requests a double-click (`kCGMouseEventClickState = 2`).
    case mouseClick(button: MouseButton, count: UInt8)
    /// Relative scroll, in pixel units. Signed.
    case scroll(dx: Int16, dy: Int16)
    case keyDown(keyCode: UInt16, modifiers: ModifierFlags)
    case keyUp(keyCode: UInt16, modifiers: ModifierFlags)
    /// Arbitrary text injected via `CGEventKeyboardSetUnicodeString` — no keycode mapping needed.
    case unicodeText(String)
    /// Sets the sticky modifier state (e.g. a held ⌘ from an on-screen modifier row).
    case setModifiers(ModifierFlags)

    var opcode: InputOpcode {
        switch self {
        case .mouseMove: .mouseMove
        case .mouseDown: .mouseDown
        case .mouseUp: .mouseUp
        case .mouseClick: .mouseClick
        case .scroll: .scroll
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .unicodeText: .unicodeText
        case .setModifiers: .setModifiers
        }
    }
}
