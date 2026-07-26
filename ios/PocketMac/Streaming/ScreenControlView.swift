import UIKit
import SwiftUI
import PocketMacKit

/// The interactive remote-desktop surface: hosts the live video and a full multi-touch gesture set so
/// the Mac feels operable from the phone.
///
/// - **tap** → click where you tapped
/// - **hold + drag** → click-drag (move windows, drag files)
/// - **two-finger pan** → scroll
/// - **pinch** → zoom the view (client-side); **one-finger drag** pans when zoomed, else moves the cursor
final class ScreenControlView: UIView, UIGestureRecognizerDelegate {
    let host = ScreenHostView()
    var send: ((Frame) -> Void)?
    /// The Mac's frame geometry, learned from the first decoded video frame.
    ///
    /// Deliberately optional. It used to default to 16:10, which is a guess — and a wrong one for
    /// most external displays. Every tap before the first frame arrived was normalised against that
    /// fiction and landed tens of points out, which felt like "the first couple of taps are always
    /// wrong". Refusing to map a tap until the real aspect is known is better than mapping it wrongly.
    var videoSize: CGSize?

    private var zoomScale: CGFloat = 1
    private var panOffset: CGPoint = .zero
    private var holdDidMove = false
    private var holdDownSent = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
        addSubview(host)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        let oneFinger = UIPanGestureRecognizer(target: self, action: #selector(onOneFingerPan))
        oneFinger.minimumNumberOfTouches = 1; oneFinger.maximumNumberOfTouches = 1
        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan))
        twoFinger.minimumNumberOfTouches = 2; twoFinger.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(onHoldDrag))
        hold.minimumPressDuration = 0.35

        for g in [tap, oneFinger, twoFinger, pinch, hold] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Let pinch + two-finger pan work together; keep others independent.
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) ||
        (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyZoom()
    }

    private func applyZoom() {
        host.frame = CGRect(x: panOffset.x, y: panOffset.y,
                            width: bounds.width * zoomScale, height: bounds.height * zoomScale)
    }

    private func clampOffset() {
        panOffset.x = min(0, max(bounds.width - bounds.width * zoomScale, panOffset.x))
        panOffset.y = min(0, max(bounds.height - bounds.height * zoomScale, panOffset.y))
    }

    // MARK: Gestures

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let n = normalized(g.location(in: self)) else { return }
        send?(.input(.mouseMoveAbsolute(x: n.0, y: n.1)))
        send?(.input(.mouseClick(button: .left, count: 1)))
    }

    @objc private func onOneFingerPan(_ g: UIPanGestureRecognizer) {
        if zoomScale > 1.01 {
            // Pan the zoomed view.
            let t = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            panOffset.x += t.x; panOffset.y += t.y
            clampOffset(); applyZoom()
        } else {
            // Full view: move the cursor to follow the finger (position preview).
            if let n = normalized(g.location(in: self)) {
                send?(.input(.mouseMoveAbsolute(x: n.0, y: n.1)))
            }
        }
    }

    @objc private func onTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let dx = Int16(clamping: Int(-t.x * 1.5))
        let dy = Int16(clamping: Int(-t.y * 1.5))
        if dx != 0 || dy != 0 { send?(.input(.scroll(dx: dx, dy: dy))) }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed else { return }
        let center = g.location(in: self)
        let old = zoomScale
        zoomScale = min(max(zoomScale * g.scale, 1), 4)
        g.scale = 1
        // Keep the pinch center stable.
        let factor = zoomScale / old
        panOffset.x = center.x - (center.x - panOffset.x) * factor
        panOffset.y = center.y - (center.y - panOffset.y) * factor
        clampOffset(); applyZoom()
    }

    /// Hold still and release → right-click. Hold then drag → click-drag (move windows, drag files).
    @objc private func onHoldDrag(_ g: UILongPressGestureRecognizer) {
        // The end of a gesture must be handled even when the finger is somewhere unmappable — the
        // letterbox bars, or off the content entirely. Guarding the whole method on a coordinate
        // meant lifting your finger over a bar skipped `.ended`, so the Mac's left button stayed
        // down: every later move dragged, and the next tap finished a selection you never began.
        // A button that is down must always be released; only the *position* needs a valid mapping.
        let n = normalized(g.location(in: self))
        switch g.state {
        case .began:
            guard let n else { return }
            holdDidMove = false
            holdDownSent = false
            send?(.input(.mouseMoveAbsolute(x: n.0, y: n.1)))
        case .changed:
            guard let n else { return }   // ignore movement outside the image, keep the drag alive
            if !holdDidMove { // first movement → this is a drag: press the button now
                holdDidMove = true
                holdDownSent = true
                send?(.input(.mouseDown(.left)))
            }
            send?(.input(.mouseMoveAbsolute(x: n.0, y: n.1)))
        case .ended, .cancelled, .failed:
            if holdDownSent {
                send?(.input(.mouseUp(.left)))                       // finished a drag
                holdDownSent = false
            } else if n != nil {
                send?(.input(.mouseClick(button: .right, count: 1))) // stationary hold → right-click
            }
        default:
            break
        }
    }

    // MARK: Coordinate mapping (view point → normalized 0…65535 on the Mac's display)

    private func normalized(_ point: CGPoint) -> (UInt16, UInt16)? {
        // Into the (possibly zoomed/panned) host's coordinate space.
        let hostFrame = host.frame
        guard let videoSize, hostFrame.width > 0, hostFrame.height > 0,
              videoSize.width > 0, videoSize.height > 0 else { return nil }
        let hp = CGPoint(x: point.x - hostFrame.minX, y: point.y - hostFrame.minY)
        // Aspect-fit content rect inside the host view.
        let hostAspect = hostFrame.width / hostFrame.height
        let videoAspect = videoSize.width / videoSize.height
        var cw = hostFrame.width, ch = hostFrame.height
        if videoAspect > hostAspect { ch = hostFrame.width / videoAspect } else { cw = hostFrame.height * videoAspect }
        let ox = (hostFrame.width - cw) / 2, oy = (hostFrame.height - ch) / 2
        let fx = (hp.x - ox) / cw, fy = (hp.y - oy) / ch
        guard fx >= 0, fx <= 1, fy >= 0, fy <= 1 else { return nil }
        // Round rather than truncate: truncation biases every coordinate consistently towards the
        // top-left, and the bias is free to remove.
        return (UInt16((fx * 65535).rounded()), UInt16((fy * 65535).rounded()))
    }
}

/// SwiftUI wrapper for the interactive screen surface.
struct ScreenControlSurface: UIViewRepresentable {
    let connection: ConnectionController

    func makeUIView(context: Context) -> ScreenControlView {
        let view = ScreenControlView()
        view.send = { frame in connection.send(frame) }
        connection.onVideoFrame = { [weak view] data, w, h in
            guard let view else { return }
            view.host.enqueue(annexB: data)
            if w > 0, h > 0 { view.videoSize = CGSize(width: w, height: h) }
        }
        return view
    }

    func updateUIView(_ uiView: ScreenControlView, context: Context) {}
}
