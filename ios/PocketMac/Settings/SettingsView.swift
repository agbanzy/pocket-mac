import SwiftUI
import PocketMacKit

/// Shared preference keys so control surfaces (trackpad, scroll) can read what Settings writes.
enum PMSettings {
    static let sensitivityKey = "com.innoedge.pocketmac.pointerSensitivity"   // 0.5…2.0, default 1.0
    static let hapticsKey = "com.innoedge.pocketmac.haptics"                  // Bool, default true
    static let naturalScrollKey = "com.innoedge.pocketmac.naturalScroll"      // Bool, default true
}

/// The Settings hub — presented as a sheet. Gives the previously code-only preferences a real home:
/// relay endpoint, pointer/haptics/scroll behaviour, the paired-Mac record + unpair, and About.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage(PMSettings.sensitivityKey) private var sensitivity = 1.0
    @AppStorage(PMSettings.hapticsKey) private var haptics = true
    @AppStorage(PMSettings.naturalScrollKey) private var naturalScroll = true
    @AppStorage(AppModel.relayURLDefaultsKey) private var relayURL = AppModel.defaultRelayURL

    @State private var confirmUnpair = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PM.space.xl) {
                    connectionSection
                    controlSection
                    if app.pairedMac != nil { pairedSection }
                    aboutSection
                }
                .padding(PM.space.lg)
            }
            .background(PM.color.background)
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.pmHeadline)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Connection

    private var connectionSection: some View {
        PMSection(title: "Connection",
                  footer: "Away from your Wi‑Fi, traffic routes through this zero‑knowledge relay. It never sees your screen or keystrokes.") {
            let path = app.connection.currentPath
            PMRow(icon: path.isLAN ? "wifi" : "globe",
                  iconTint: path.isLAN ? PM.color.success : PM.color.info,
                  title: "Active path",
                  subtitle: app.connection.state.isSecured ? path.friendly : "Not connected") {
                Text(app.connection.state.isSecured ? (path.isLAN ? "Same Wi‑Fi" : "Anywhere") : "—")
                    .font(.pmCaption).foregroundStyle(PM.color.textSecondary)
            }
            VStack(alignment: .leading, spacing: PM.space.sm) {
                HStack(spacing: PM.space.md) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(PM.color.accent)
                        .frame(width: 26, height: 26)
                        .background(PM.color.accentSoft, in: RoundedRectangle(cornerRadius: PM.radius.sm, style: .continuous))
                    Text("Relay endpoint").font(.pmBody).foregroundStyle(PM.color.textPrimary)
                    Spacer()
                    if relayURL != AppModel.defaultRelayURL {
                        Button("Reset") { relayURL = AppModel.defaultRelayURL; applyRelay() }
                            .font(.pmCaption).foregroundStyle(PM.color.accent)
                    }
                }
                TextField("wss://…", text: $relayURL)
                    .font(.pmMono).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .foregroundStyle(PM.color.textSecondary)
                    .padding(PM.space.sm)
                    .background(PM.color.surfaceHigh, in: RoundedRectangle(cornerRadius: PM.radius.sm))
                    .onSubmit(applyRelay)
            }
            .padding(.horizontal, PM.space.lg).padding(.vertical, PM.space.md)
        }
    }

    private func applyRelay() {
        if let url = URL(string: relayURL) { app.pathCoordinator.relayURL = url }
    }

    // MARK: Control

    private var controlSection: some View {
        PMSection(title: "Control") {
            VStack(alignment: .leading, spacing: PM.space.sm) {
                HStack {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(PM.color.accent)
                        .frame(width: 26, height: 26)
                        .background(PM.color.accentSoft, in: RoundedRectangle(cornerRadius: PM.radius.sm, style: .continuous))
                    Text("Pointer speed").font(.pmBody).foregroundStyle(PM.color.textPrimary)
                    Spacer()
                    Text(String(format: "%.1f×", sensitivity)).font(.pmMono).foregroundStyle(PM.color.textSecondary)
                }
                Slider(value: $sensitivity, in: 0.5...2.0, step: 0.1).tint(PM.color.accent)
            }
            .padding(.horizontal, PM.space.lg).padding(.vertical, PM.space.md)
            Divider().overlay(PM.color.hairline).padding(.leading, 52)
            PMRow(icon: "hand.tap", title: "Haptic feedback") {
                Toggle("", isOn: $haptics).labelsHidden().tint(PM.color.accent)
            }
            PMRow(icon: "arrow.up.arrow.down", title: "Natural scrolling", showsDivider: false) {
                Toggle("", isOn: $naturalScroll).labelsHidden().tint(PM.color.accent)
            }
        }
    }

    // MARK: Paired Mac

    private var pairedSection: some View {
        PMSection(title: "Paired Mac") {
            PMRow(icon: "laptopcomputer", title: app.pairedMac?.displayName ?? "Mac",
                  subtitle: "Paired · end‑to‑end encrypted", showsDivider: true)
            Button(role: .destructive) { confirmUnpair = true } label: {
                PMRow(icon: "minus.circle", iconTint: PM.color.danger, title: "Unpair this Mac", showsDivider: false) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        }
        .confirmationDialog("Unpair this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { app.unpair(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to scan the QR code again to reconnect.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        PMSection(title: "About") {
            PMRow(icon: "info.circle", title: "Version", showsDivider: true) {
                Text(appVersion).font(.pmMono).foregroundStyle(PM.color.textSecondary)
            }
            Button { openURL(URL(string: "https://github.com/agbanzy/pocket-mac")!) } label: {
                PMRow(icon: "chevron.left.forwardslash.chevron.right", title: "Source code", showsDivider: true) {
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(PM.color.textTertiary)
                }
            }.buttonStyle(.plain)
            Button { openURL(URL(string: "https://github.com/agbanzy/pocket-mac/blob/main/PRIVACY.md")!) } label: {
                PMRow(icon: "hand.raised", title: "Privacy policy", showsDivider: true) {
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(PM.color.textTertiary)
                }
            }.buttonStyle(.plain)
            Button { openURL(URL(string: "https://buymeacoffee.com/agbanzy")!) } label: {
                PMRow(icon: "cup.and.saucer.fill", iconTint: PM.color.warning, title: "Buy me a coffee",
                      subtitle: "Support an open‑source project", showsDivider: false) {
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(PM.color.textTertiary)
                }
            }.buttonStyle(.plain)
        }
    }
}
