import CoreHaptics

/// Thin Core Haptics wrapper for trackpad click feedback. No-ops on hardware without haptics (all
/// current Simulators), so callers never need to check support themselves.
@MainActor
final class HapticsEngine {
    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func prepare() {
        guard supported, engine == nil else { return }
        engine = try? CHHapticEngine()
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        engine?.stoppedHandler = { _ in }
        try? engine?.start()
    }

    /// A short, crisp tap — fired on click.
    func click(intensity: Float = 0.85, sharpness: Float = 0.65) {
        guard supported, let engine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // Best-effort feedback; a failed haptic must never affect input.
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
