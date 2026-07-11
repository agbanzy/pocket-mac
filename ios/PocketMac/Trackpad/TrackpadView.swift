import SwiftUI
import PocketMacKit

/// SwiftUI bridge to `TrackpadSurface`. Owns a `HapticsEngine` via its coordinator and forwards every
/// synthesized `Frame` to the caller.
struct TrackpadView: UIViewRepresentable {
    var sensitivity: CGFloat = 1.7
    var scrollSensitivity: CGFloat = 1.1
    var hapticsEnabled = true
    var onFrame: (Frame) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(hapticsEnabled: hapticsEnabled) }

    func makeUIView(context: Context) -> TrackpadSurface {
        let surface = TrackpadSurface()
        let coordinator = context.coordinator
        surface.onFrame = onFrame
        surface.onClick = { [weak coordinator] in coordinator?.click() }
        surface.pointerSensitivity = sensitivity
        surface.scrollSensitivity = scrollSensitivity
        coordinator.prepareHaptics()
        return surface
    }

    func updateUIView(_ surface: TrackpadSurface, context: Context) {
        surface.onFrame = onFrame
        surface.pointerSensitivity = sensitivity
        surface.scrollSensitivity = scrollSensitivity
        context.coordinator.hapticsEnabled = hapticsEnabled
    }

    @MainActor
    final class Coordinator {
        private let haptics = HapticsEngine()
        var hapticsEnabled: Bool

        init(hapticsEnabled: Bool) { self.hapticsEnabled = hapticsEnabled }

        func prepareHaptics() { haptics.prepare() }

        func click() {
            guard hapticsEnabled else { return }
            haptics.click()
        }
    }
}

/// The framed trackpad panel used on the remote surface: a rounded card, a usage hint, a
/// not-connected veil (that still lets touches through so the pad feels live), and idle-timer
/// suppression while it's on screen.
struct TrackpadPanel: View {
    let sink: InputSink
    let connected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )

            TrackpadView { frame in sink.send(frame) }
                .clipShape(RoundedRectangle(cornerRadius: 24))

            VStack {
                Spacer()
                Text("Drag to move · tap to click · two fingers scroll / right-click")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .multilineTextAlignment(.center)
            }
            .allowsHitTesting(false)

            if !connected {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "wifi.slash").font(.title2)
                            Text("Not connected").font(.subheadline.weight(.semibold))
                            Text("Connect to your Mac to control it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    )
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
