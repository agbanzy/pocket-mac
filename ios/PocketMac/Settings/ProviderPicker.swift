import SwiftUI
import PocketMacKit

/// One model provider the Mac reported. Decoded from the `providerList` frame's JSON payload, so
/// adding a field on the Mac needs no protocol change here.
struct ProviderOption: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let available: Bool
    let needsKey: Bool
}

/// Choose which brain runs your tasks: your Claude subscription, the Claude API, Grok, or a local
/// model. The Mac decides what is genuinely usable and says why when something isn't — a provider
/// that looks selectable but fails at task time is worse than one shown as unavailable.
struct ProviderPicker: View {
    @Environment(AppModel.self) private var app

    private var providers: [ProviderOption] { app.connection.providers }
    private var active: String { app.connection.activeProvider }
    private var connected: Bool { app.connection.state.isSecured }

    var body: some View {
        PMSection(title: "Model",
                  footer: "Your subscription runs tasks without an API key. The Claude API is the "
                        + "fastest option. Grok and the API need a key on the Mac.") {
            if !connected {
                PMRow(icon: "bolt.horizontal.circle", iconTint: PM.color.textTertiary,
                      title: "Connect to your Mac", subtitle: "to see what it can run",
                      showsDivider: false)
            } else if providers.isEmpty {
                PMRow(icon: "ellipsis", iconTint: PM.color.textTertiary,
                      title: "Checking what this Mac can run…", showsDivider: false)
            } else {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, option in
                    Button {
                        guard option.available else { return }
                        app.connection.setProvider(option.id)
                    } label: {
                        PMRow(icon: glyph(option.id),
                              iconTint: option.available ? PM.color.accent : PM.color.textTertiary,
                              title: option.name,
                              subtitle: option.detail,
                              showsDivider: index < providers.count - 1) {
                            if active == option.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(PM.color.success)
                            } else if !option.available {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(PM.color.warning)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.available)
                    .opacity(option.available ? 1 : 0.55)
                }
            }
        }
        .task {
            // Ask on appear so the list reflects the Mac's real state, not a cached guess.
            if connected { app.connection.requestProviders() }
        }
        .onChange(of: connected) { _, isUp in
            if isUp { app.connection.requestProviders() }
        }
    }

    private func glyph(_ id: String) -> String {
        switch id {
        case "claude-code": "person.badge.key"
        case "claude": "sparkles"
        case "grok": "bolt.fill"
        case "ollama", "lm-studio", "llama.cpp": "desktopcomputer"
        default: "cpu"
        }
    }
}
