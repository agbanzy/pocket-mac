import SwiftUI
import PocketMacKit

/// The "Ask" surface: type a natural-language task, run it on the Mac's Claude agent, and watch a
/// live activity log stream back. Sensitive steps pause for a PIN. Uses the shared design system.
struct AskView: View {
    @Environment(AppModel.self) private var app
    @State private var prompt = ""
    @State private var pin = ""
    @State private var voice = VoiceController()
    @FocusState private var promptFocused: Bool

    /// Scroll anchor for the composer, so focusing the field brings it above the keyboard.
    private static let composerID = "composer"

    private var agent: AgentSession { app.connection.agent }
    private var connected: Bool { app.connection.state.isSecured }
    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    private let suggestions = ["Open Safari and search the web",
                               "Summarize the document I have open",
                               "Take a screenshot and describe it",
                               "Open Notes and start a new note"]

    /// One scroll container for the whole surface.
    ///
    /// The transcript deliberately does **not** get its own `ScrollView`. With the keyboard up, the
    /// visible height roughly halves; if the page itself can't scroll, the Run button and the newest
    /// events sit under the keyboard with no way to reach them. A single scroll view also means one
    /// unambiguous target for the drag-to-dismiss gesture, instead of two nested ones fighting.
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: PM.space.lg) {
                    // The orb is status, and status is not what you need while you are writing —
                    // it costs ~300pt that the keyboard has just taken away. Collapsing it while
                    // the field has focus is what actually keeps the composer and Run button on
                    // screen; scrolling alone races the keyboard animation and loses.
                    if !promptFocused {
                        PresenceView(
                            phase: .from(agent: agent, listening: voice.isListening,
                                         speaking: voice.phase == .speaking),
                            caption: agent.events.last?.text ?? "")
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                    promptCard
                        .id(Self.composerID)
                    runButton
                    if let reason = agent.pendingPinReason { pinCard(reason) }
                    activityLog
                }
                .padding(PM.space.lg)
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(.snappy, value: promptFocused)
            }
            // Drag down anywhere to put the keyboard away — the gesture people already know from
            // Messages and Mail, and the only one that works when the Done button is off screen.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: promptFocused) { _, focused in
                guard focused else { return }
                // After the keyboard's safe-area inset lands, not before — otherwise this scrolls
                // against the old, taller viewport and does nothing.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation { proxy.scrollTo(Self.composerID, anchor: .top) }
                }
            }
            .onChange(of: agent.events.count) { _, _ in
                if let last = agent.events.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                // Speak only the outcome — narrating every step would talk over you mid-task.
                guard let last = agent.events.last,
                      last.kind == .done || last.kind == .error else { return }
                voice.speak(last.text)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { promptFocused = false }
                    .font(.pmHeadline)
            }
        }
        .onAppear {
            // Ask once on arrival so the first mic tap isn't stalled behind two system dialogs.
            voice.primePermissions()
        }
        .onDisappear {
            voice.stopDictation()
            voice.stopSpeaking()
        }
    }

    private var promptCard: some View {
        PMCard {
            VStack(alignment: .leading, spacing: PM.space.md) {
                HStack {
                    Text("Ask your Mac").font(.pmHeadline).foregroundStyle(PM.color.textPrimary)
                    Spacer()
                    Button {
                        voice.speaksResults.toggle()
                        if !voice.speaksResults { voice.stopSpeaking() }
                    } label: {
                        Image(systemName: voice.speaksResults ? "speaker.wave.2.fill" : "speaker.slash")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(voice.speaksResults ? PM.color.accent : PM.color.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(voice.speaksResults ? "Speaking results on" : "Speaking results off")
                    micButton
                }
                if let problem = voice.problem {
                    Text(problem).font(.pmCaption).foregroundStyle(PM.color.warning)
                }
                // A growing TextField rather than a TextEditor: inside a ScrollView, a TextEditor
                // brings its own scroll view, so a long prompt scrolls within a 72pt window while
                // the page stays put — you end up typing into a slot you can't see out of. This
                // grows with the text up to eight lines, then the page scrolls, which is one
                // scroll surface instead of two.
                TextField("Tell your Mac what to do…", text: $prompt, axis: .vertical)
                    .font(.pmBody)
                    .foregroundStyle(PM.color.textPrimary)
                    .lineLimit(3...8)
                    .focused($promptFocused)
                    .submitLabel(.return)
                    .padding(PM.space.sm)
                    .background(PM.color.surfaceHigh,
                                in: RoundedRectangle(cornerRadius: PM.radius.sm))
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

    /// Dictation. The transcript lands in the prompt field rather than running straight away — you
    /// read what it heard before anything touches your Mac.
    private var micButton: some View {
        Button {
            voice.toggleDictation { text in prompt = text }
        } label: {
            Image(systemName: voice.isListening ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(voice.isListening ? .white : PM.color.accent)
                .frame(width: 30, height: 30)
                .background(voice.isListening ? PM.color.danger : PM.color.accentSoft, in: Circle())
                .symbolEffect(.pulse, isActive: voice.isListening)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.isListening ? "Stop dictation" : "Dictate a task")
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

    /// Plain content, not a scroll view — the page scrolls it. See the note on `body`.
    private var activityLog: some View {
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
