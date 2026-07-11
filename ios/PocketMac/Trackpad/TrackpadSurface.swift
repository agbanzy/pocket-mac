import UIKit
import PocketMacKit

/// The high-frequency trackpad surface. Reads `event.coalescedTouches(for:)` for smooth deltas and
/// emits **relative** input frames — never absolute coordinates, so the Mac applies its own pointer
/// acceleration and never needs the phone to know its screen geometry. Deliberately UIKit rather than
/// SwiftUI `DragGesture`, which is too coarse for pointer work.
///
/// Gestures:
/// - one-finger move → `mouseMove`
/// - two-finger move → `scroll`
/// - one-finger tap → left `mouseClick` (double-tap → `count: 2`)
/// - two-finger tap → right `mouseClick`
final class TrackpadSurface: UIView {
    /// Emitted for every synthesized input event. Called on the main thread.
    var onFrame: ((Frame) -> Void)?
    /// Fired when a click is synthesized, for haptic feedback.
    var onClick: (() -> Void)?

    var pointerSensitivity: CGFloat = 1.7
    var scrollSensitivity: CGFloat = 1.1
    var naturalScrolling = true

    // Gesture bookkeeping
    private var activeTouches: Set<UITouch> = []
    private var primaryTouch: UITouch?
    private var gestureStart: CFTimeInterval = 0
    private var accumulatedDistance: CGFloat = 0
    private var maxFingerCount = 0

    // Tap / double-tap detection
    private var pendingClickTask: Task<Void, Never>?
    private let tapMovementThreshold: CGFloat = 12
    private let tapMaxDuration: CFTimeInterval = 0.35
    private let doubleTapWindow: Double = 0.28

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Touch tracking

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.isEmpty {
            gestureStart = CACurrentMediaTime()
            accumulatedDistance = 0
            maxFingerCount = 0
        }
        activeTouches.formUnion(touches)
        primaryTouch = activeTouches.first
        maxFingerCount = max(maxFingerCount, activeTouches.count)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let event, let primary = primaryTouch, activeTouches.contains(primary) else { return }

        // Sum the deltas across every coalesced sub-sample for full-resolution motion.
        let coalesced = event.coalescedTouches(for: primary) ?? [primary]
        var last = primary.previousLocation(in: self)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        for touch in coalesced {
            let p = touch.location(in: self)
            dx += p.x - last.x
            dy += p.y - last.y
            last = p
        }
        accumulatedDistance += hypot(dx, dy)

        if activeTouches.count >= 2 {
            emitScroll(dx: dx, dy: dy)
        } else {
            emitMove(dx: dx, dy: dy)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let elapsed = CACurrentMediaTime() - gestureStart
        let wasTap = accumulatedDistance < tapMovementThreshold && elapsed < tapMaxDuration
        let fingers = maxFingerCount

        activeTouches.subtract(touches)
        if activeTouches.isEmpty {
            if wasTap { fireTap(fingers: fingers) }
            primaryTouch = nil
        } else {
            primaryTouch = activeTouches.first
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        if activeTouches.isEmpty { primaryTouch = nil }
    }

    // MARK: Emit

    private func emitMove(dx: CGFloat, dy: CGFloat) {
        let sx = clampInt16(dx * pointerSensitivity)
        let sy = clampInt16(dy * pointerSensitivity)
        guard sx != 0 || sy != 0 else { return }
        onFrame?(.input(.mouseMove(dx: sx, dy: sy)))
    }

    private func emitScroll(dx: CGFloat, dy: CGFloat) {
        // Natural scrolling: content follows the fingers (matches the macOS default).
        let factor = scrollSensitivity * (naturalScrolling ? -1 : 1)
        let sx = clampInt16(dx * factor)
        let sy = clampInt16(dy * factor)
        guard sx != 0 || sy != 0 else { return }
        onFrame?(.input(.scroll(dx: sx, dy: sy)))
    }

    private func fireTap(fingers: Int) {
        if fingers >= 2 {
            // Two-finger tap → right click. Cancel any pending single-click.
            pendingClickTask?.cancel()
            pendingClickTask = nil
            onFrame?(.input(.mouseClick(button: .right, count: 1)))
            onClick?()
            return
        }

        if pendingClickTask != nil {
            // Second tap within the window → promote to a double-click.
            pendingClickTask?.cancel()
            pendingClickTask = nil
            onFrame?(.input(.mouseClick(button: .left, count: 2)))
            onClick?()
        } else {
            // Defer the single-click briefly to see whether a double-tap follows.
            let window = doubleTapWindow
            pendingClickTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(window))
                guard let self, !Task.isCancelled else { return }
                self.pendingClickTask = nil
                self.onFrame?(.input(.mouseClick(button: .left, count: 1)))
                self.onClick?()
            }
        }
    }

    private func clampInt16(_ value: CGFloat) -> Int16 {
        let r = value.rounded()
        if r >= CGFloat(Int16.max) { return .max }
        if r <= CGFloat(Int16.min) { return .min }
        return Int16(r)
    }
}
