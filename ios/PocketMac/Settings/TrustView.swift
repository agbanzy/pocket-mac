import AVFoundation
import Speech
import SwiftUI
import PocketMacKit

/// What the assistant can see and do, in plain terms, with the current state of each permission.
///
/// This exists because the honest version of "an app that watches your screen and moves your mouse"
/// is a list you can read, not a paragraph in a privacy policy. Every row states the capability, why
/// it is needed, and whether it is currently granted — and every one is revocable from Settings.
struct TrustView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    @State private var micGranted = false
    @State private var speechGranted = false

    private var connected: Bool { app.connection.state.isSecured }

    var body: some View {
        PMSection(title: "What it can do",
                  footer: "Nothing here is silent. Your Mac shows a menu-bar indicator while the "
                        + "agent is running, every task is recorded in History, and any permission "
                        + "can be withdrawn in Settings.") {
            row(icon: "display", title: "See your Mac's screen",
                detail: "Screenshots are sent to the model you chose, to decide the next step.",
                state: connected ? .granted : .unknown, action: nil)

            row(icon: "cursorarrow.click", title: "Control your Mac",
                detail: "Moves the pointer, clicks and types — the same as sitting at it.",
                state: connected ? .granted : .unknown, action: nil)

            row(icon: "mic", title: "Microphone",
                detail: "Only while you hold the mic button, to dictate a task.",
                state: micGranted ? .granted : .denied, action: openSettings)

            row(icon: "waveform", title: "Speech recognition",
                detail: "Turns your dictation into text.",
                state: speechGranted ? .granted : .denied, action: openSettings)

            row(icon: "clock.arrow.circlepath", title: "Run on a schedule",
                detail: "Only the tasks you add under Schedule, only while your Mac is awake.",
                state: app.connection.schedules.contains(where: { $0.enabled }) ? .granted : .off,
                action: nil, last: true)
        }
        .task { refresh() }
    }

    private enum Grant { case granted, denied, off, unknown }

    private func refresh() {
        micGranted = AVAudioApplication.shared.recordPermission == .granted
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    @ViewBuilder
    private func row(icon: String, title: String, detail: String,
                     state: Grant, action: (() -> Void)?, last: Bool = false) -> some View {
        let content = PMRow(icon: icon, iconTint: tint(state), title: title,
                            subtitle: detail, showsDivider: !last) {
            switch state {
            case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(PM.color.success)
            case .denied: Text("Off").font(.pmCaption).foregroundStyle(PM.color.warning)
            case .off: Text("None").font(.pmCaption).foregroundStyle(PM.color.textTertiary)
            case .unknown: Text("—").font(.pmCaption).foregroundStyle(PM.color.textTertiary)
            }
        }
        if let action, state == .denied {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private func tint(_ s: Grant) -> Color {
        switch s {
        case .granted: PM.color.accent
        case .denied: PM.color.warning
        default: PM.color.textTertiary
        }
    }
}
