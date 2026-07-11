import SwiftUI

/// Persistent status pill showing link state, the paired device name, and a live latency readout.
struct ConnectionChip: View {
    let state: ConnectionState
    let latencyMS: Int?
    var deviceName: String?
    /// Which path the live session runs over (LAN vs Remote), shown when secured.
    var path: ConnectionPath?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.systemImage)
                .symbolEffect(.pulse, isActive: state.isBusy)
                .font(.caption.weight(.semibold))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(.caption.weight(.semibold))
                if let secondaryText {
                    Text(secondaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if state.isSecured {
                Spacer(minLength: 6)
                Label(latencyText, systemImage: "timer")
                    .labelStyle(.titleOnly)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(state.tint.opacity(0.15), in: Capsule())
        .foregroundStyle(state.tint)
        .overlay(Capsule().strokeBorder(state.tint.opacity(0.35), lineWidth: 1))
        .animation(.snappy, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection \(state.label)")
    }

    private var primaryText: String {
        switch state {
        case .secured: deviceName ?? "Secured"
        default: state.label
        }
    }

    private var secondaryText: String? {
        switch state {
        case .secured: path.map { "Encrypted · \($0.rawValue)" } ?? "Encrypted session"
        case .offline(let reason): reason
        case .connecting: "Handshaking…"
        case .discovering: "Looking for your Mac"
        case .idle: deviceName.map { "Paired · \($0)" }
        }
    }

    private var latencyText: String {
        guard let latencyMS else { return "— ms" }
        return "\(latencyMS) ms"
    }
}
