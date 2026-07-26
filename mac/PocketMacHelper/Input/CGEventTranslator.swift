import Foundation
import CoreGraphics
import PocketMacKit

/// Translates decoded ``InputFrame``s into real macOS input via Quartz Event Services (`CGEvent`).
///
/// Requires the **Accessibility** permission (`kTCCServiceAccessibility`) to post — a pure event
/// *sender* does NOT need Input Monitoring. Thread-safe: `CGEventPost` may be called from any
/// thread; the small sticky-modifier / button state is guarded by a lock.
final class CGEventTranslator: @unchecked Sendable {
    private let lock = NSLock()
    private var stickyModifiers: ModifierFlags = []
    private var leftButtonDown = false
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Where we last *told* the cursor to go.
    ///
    /// Clicks must be posted at this position, never at one read back from WindowServer. A tap
    /// arrives as two frames — move, then click — and `CGEvent.post` only enqueues; it does not wait
    /// for WindowServer to apply the move. Asking "where is the cursor?" immediately afterwards can
    /// therefore still answer with the *previous* position, and the click lands on whatever the user
    /// tapped last. That reads as random rather than merely offset, and it was the main reason taps
    /// felt inaccurate. Tracking the commanded position removes the race entirely.
    ///
    /// Nil until we have moved the cursor at least once, in which case there is no commanded
    /// position and reading the live one is correct.
    ///
    /// It also *expires*. The race it exists to win lasts milliseconds — the gap between posting a
    /// move and WindowServer applying it. Beyond that the live cursor is the truth: someone at the
    /// Mac may have moved the physical mouse, and the trackpad surface sends a bare click with no
    /// preceding move, which would otherwise be posted wherever the phone last pointed rather than
    /// where the cursor actually is.
    private var commandedPosition: CGPoint?
    private var commandedAt: Date?

    /// How long a commanded position stays authoritative. Long enough to cover the post-then-read
    /// race by orders of magnitude, far short of any human pause between moving and clicking.
    private static let commandedPositionTTL: TimeInterval = 0.5

    func handle(_ frame: InputFrame) {
        switch frame {
        case .mouseMove(let dx, let dy):
            moveCursor(dx: Int(dx), dy: Int(dy))
        case .mouseDown(let button):
            setButton(button, down: true)
        case .mouseUp(let button):
            setButton(button, down: false)
        case .mouseClick(let button, let count):
            click(button, count: max(1, Int(count)))
        case .scroll(let dx, let dy):
            scroll(dx: Int(dx), dy: Int(dy))
        case .keyDown(let code, let modifiers):
            key(code: code, down: true, modifiers: modifiers)
        case .keyUp(let code, let modifiers):
            key(code: code, down: false, modifiers: modifiers)
        case .unicodeText(let text):
            type(text)
        case .setModifiers(let modifiers):
            lock.lock(); stickyModifiers = modifiers; lock.unlock()
        case .mouseMoveAbsolute(let x, let y):
            moveAbsolute(x: x, y: y)
        }
    }

    /// Moves the cursor to a normalized (0…65535) absolute position on the main display — the
    /// screen-view "tap where you see it" path.
    private func moveAbsolute(x: UInt16, y: UInt16) {
        let bounds = CGDisplayBounds(streamedDisplayID())
        let target = CGPoint(x: bounds.minX + CGFloat(x) / 65535.0 * bounds.width,
                             y: bounds.minY + CGFloat(y) / 65535.0 * bounds.height)
        lock.lock(); let dragging = leftButtonDown
        commandedPosition = target; commandedAt = Date(); lock.unlock()
        CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    // MARK: Pointer

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// The position a click should be posted at: the one we commanded, falling back to the live
    /// cursor only when we have never moved it. See ``commandedPosition``.
    private func clickPosition() -> CGPoint {
        lock.lock()
        let commanded = commandedPosition
        let at = commandedAt
        lock.unlock()
        guard let commanded, let at, Date().timeIntervalSince(at) < Self.commandedPositionTTL else {
            return currentLocation()
        }
        return commanded
    }

    /// The display the phone is actually watching.
    ///
    /// The capture side picks `content.displays.first`; injecting into `CGMainDisplayID()` would be
    /// a different display whenever those disagree, so taps would be scaled by one screen's bounds
    /// and delivered to another. ``ScreenStreamer`` publishes the display it opened; until it does,
    /// the main display is the right assumption.
    private func streamedDisplayID() -> CGDirectDisplayID {
        ScreenStreamer.streamingDisplayID ?? CGMainDisplayID()
    }

    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        let bounds = CGDisplayBounds(streamedDisplayID())
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private func moveCursor(dx: Int, dy: Int) {
        // Relative motion starts from the live cursor so the pointer still follows the physical
        // mouse if someone is sitting at the Mac.
        let current = currentLocation()
        let target = clampToDisplays(CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy)))
        lock.lock(); let dragging = leftButtonDown
        commandedPosition = target; commandedAt = Date(); lock.unlock()
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        let button: CGMouseButton = dragging ? .left : .left
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    private func cgButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    private func downType(_ button: MouseButton) -> CGEventType {
        switch button { case .left: .leftMouseDown; case .right: .rightMouseDown; case .middle: .otherMouseDown }
    }

    private func upType(_ button: MouseButton) -> CGEventType {
        switch button { case .left: .leftMouseUp; case .right: .rightMouseUp; case .middle: .otherMouseUp }
    }

    private func setButton(_ button: MouseButton, down: Bool) {
        if button == .left { lock.lock(); leftButtonDown = down; lock.unlock() }
        let position = clickPosition()
        let event = CGEvent(mouseEventSource: source, mouseType: down ? downType(button) : upType(button),
                            mouseCursorPosition: position, mouseButton: cgButton(button))
        event?.post(tap: .cghidEventTap)
    }

    private func click(_ button: MouseButton, count: Int) {
        let position = clickPosition()
        for _ in 0 ..< count {
            let down = CGEvent(mouseEventSource: source, mouseType: downType(button),
                               mouseCursorPosition: position, mouseButton: cgButton(button))
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(mouseEventSource: source, mouseType: upType(button),
                             mouseCursorPosition: position, mouseButton: cgButton(button))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            up?.post(tap: .cghidEventTap)
        }
    }

    private func scroll(dx: Int, dy: Int) {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func flags(_ modifiers: ModifierFlags) -> CGEventFlags {
        lock.lock(); let combined = modifiers.union(stickyModifiers); lock.unlock()
        var flags: CGEventFlags = []
        if combined.contains(.shift) { flags.insert(.maskShift) }
        if combined.contains(.control) { flags.insert(.maskControl) }
        if combined.contains(.option) { flags.insert(.maskAlternate) }
        if combined.contains(.command) { flags.insert(.maskCommand) }
        if combined.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if combined.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private func key(code: UInt16, down: Bool, modifiers: ModifierFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        event?.flags = flags(modifiers)
        event?.post(tap: .cghidEventTap)
    }

    /// Injects arbitrary text without keycode mapping — `CGEventKeyboardSetUnicodeString`.
    private func type(_ text: String) {
        let scalars = Array(text.utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: scalars)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: scalars)
        up?.post(tap: .cghidEventTap)
    }
}
