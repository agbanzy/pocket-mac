import SwiftUI
import PocketMacKit

/// The "Ask" surface: type a natural-language task, run it on the Mac's Claude agent, and watch a
/// live activity log stream back. Sensitive steps pause for a PIN. Uses the shared design system.
struct AskView: View {
    @Environment(AppModel.self) private var app
    @State private var prompt = ""
    @State private var pin = ""

    private var agent: AgentSession { app.connection.agent }
    private var connected: Bool { app.connection.state.isSecured }
    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    private let suggestions = ["Open Safari and search the web",
                               "Summarize the document I have open",
                               "Take a screenshot and describe it",
                               "Open Notes and start a new note"]

    var body: some View {
        VStack(spacing: PM.space.lg) {
            promptCard
            runButton
            if let reason = agent.pendingPinReason { pinCard(reason) }
            activityLog
        }
        .padding(PM.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var promptCard: some View {
        PMCard {
            VStack(alignment: .leading, spacing: PM.space.md) {
                Text("Ask your Mac").font(.pmHeadline).foregroundStyle(PM.color.textPrimary)
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Tell your Mac what to do…")
                            .font(.pmBody).foregroundStyle(PM.color.textTertiary)
                            .padding(.top, 8).padding(.leading, 5)
                    }
                    TextEditor(text: $prompt)
                        .font(.pmBody).foregroundStyle(PM.color.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 72)
                }
                .background(PM.color.surfaceHigh, in: RoundedRectangle(cornerRadius: PM.radius.sm))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PM.space.sm) {
                        ForEach(suggestions, id: \.self) { s in
                            Button { prompt = s } label: {
                                Text(s).font(.pmCaption).foregroundStyle(PM.color.accent)
                                    .padding(.horizontal, PM.space.md).padding(.vertical, PM.space.sm)
                                    .background(PM.color.accentSoft, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var runButton: some View {
        if agent.isRunning {
            Button { app.connection.stopTask() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(PMPrimaryButtonStyle(tint: PM.color.danger))
        } else {
            Button { app.connection.runTask(trimmed, requirePin: false) } label: {
                Label("Run task", systemImage: "play.fill")
            }
            .buttonStyle(PMPrimaryButtonStyle())
            .disabled(!connected || trimmed.isEmpty)
            .opacity(!connected || trimmed.isEmpty ? 0.5 : 1)
        }
    }

    private func pinCard(_ reason: String) -> some View {
        PMCard {
            VStack(alignment: .leading, spacing: PM.space.sm) {
                Label("Confirm sensitive action", systemImage: "lock.fill")
                    .font(.pmCallout).foregroundStyle(PM.color.warning)
                Text(reason).font(.pmCaption).foregroundStyle(PM.color.textSecondary)
                HStack(spacing: PM.space.sm) {
                    SecureField("PIN", text: $pin)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    Button("Allow") { app.connection.sendPin(pin); pin = "" }
                        .buttonStyle(PMSecondaryButtonStyle())
                    Button("Deny") { app.connection.sendPin(""); pin = "" }
                        .buttonStyle(PMSecondaryButtonStyle(tint: PM.color.danger))
                }
            }
        }
    }

    private var activityLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PM.space.sm) {
                    if agent.events.isEmpty {
                        Text(connected ? "Ready — describe a task and tap Run."
                                       : "Connect to your Mac to run a task.")
                            .font(.pmCaption).foregroundStyle(PM.color.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(agent.events) { event in
                        HStack(alignment: .top, spacing: PM.space.sm) {
                            Image(systemName: icon(event.kind)).font(.caption)
                                .foregroundStyle(tint(event.kind)).frame(width: 18)
                            Text(event.text).font(.pmCaption).foregroundStyle(PM.color.textSecondary)
                            Spacer(minLength: 0)
                        }
                        .id(event.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.events.count) { _, _ in
                if let last = agent.events.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func icon(_ kind: TaskEventKind) -> String {
        switch kind {
        case .started: "play.circle"
        case .thinking: "sparkles"
        case .action: "cursorarrow.click"
        case .needsPin: "lock"
        case .done: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ kind: TaskEventKind) -> Color {
        switch kind {
        case .done: PM.color.success
        case .error: PM.color.danger
        case .needsPin: PM.color.warning
        case .action: PM.color.accent
        default: PM.color.textTertiary
        }
    }
}
