import SwiftUI
import PocketMacKit

/// The assistant's presence: one glance tells you whether it is idle, listening, thinking, or
/// acting on your Mac.
///
/// The animation is deliberately tied to *real* state, never decorative. A ring that pulses while
/// nothing is happening trains you to ignore it — and the whole point of a visible agent is that you
/// can tell, without reading, when something is touching your machine.
struct PresenceView: View {
    let phase: Phase
    /// The most recent line the agent said, shown under the orb.
    let caption: String

    enum Phase: Equatable {
        case idle, listening, thinking, acting, done, failed

        var tint: Color {
            switch self {
            case .idle: PM.color.textTertiary
            case .listening: PM.color.danger
            case .thinking: PM.color.accent
            case .acting: PM.color.info
            case .done: PM.color.success
            case .failed: PM.color.danger
            }
        }

        var glyph: String {
            switch self {
            case .idle: "circle.dotted"
            case .listening: "waveform"
            case .thinking: "sparkles"
            case .acting: "cursorarrow.rays"
            case .done: "checkmark"
            case .failed: "exclamationmark"
            }
        }

        var label: String {
            switch self {
            case .idle: "Ready"
            case .listening: "Listening"
            case .thinking: "Thinking"
            case .acting: "Working on your Mac"
            case .done: "Done"
            case .failed: "Stopped"
            }
        }

        /// Only states that represent ongoing work animate.
        var isBusy: Bool { self == .listening || self == .thinking || self == .acting }
    }

    @State private var pulse = false

    var body: some View {
        VStack(spacing: PM.space.md) {
            ZStack {
                // Two haloes, offset in phase, so "busy" reads at a glance without being frantic.
                Circle()
                    .stroke(phase.tint.opacity(0.30), lineWidth: 2)
                    .frame(width: 92, height: 92)
                    .scaleEffect(pulse && phase.isBusy ? 1.18 : 1)
                    .opacity(pulse && phase.isBusy ? 0 : 0.9)
                Circle()
                    .fill(phase.tint.opacity(0.16))
                    .frame(width: 72, height: 72)
                Image(systemName: phase.glyph)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(phase.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .animation(
                phase.isBusy
                    ? .easeOut(duration: 1.4).repeatForever(autoreverses: false)
                    : .default,
                value: pulse)
            .onAppear { pulse = true }
            .onChange(of: phase) { _, _ in pulse = true }

            Text(phase.label)
                .font(.pmCallout)
                .foregroundStyle(phase.tint)
                .contentTransition(.opacity)

            if !caption.isEmpty {
                Text(caption)
                    .font(.pmCaption)
                    .foregroundStyle(PM.color.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, PM.space.lg)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phase.label). \(caption)")
    }
}

extension PresenceView.Phase {
    /// Derive presence from what the agent is actually doing. Voice wins while listening, because
    /// that is the state the user is personally involved in.
    @MainActor
    static func from(agent: AgentSession, listening: Bool, speaking: Bool) -> PresenceView.Phase {
        if listening { return .listening }
        guard let last = agent.events.last else { return .idle }
        if agent.isRunning {
            switch last.kind {
            case .action: return .acting
            default: return .thinking
            }
        }
        switch last.kind {
        case .done: return speaking ? .thinking : .done
        case .error: return .failed
        default: return .idle
        }
    }
}
