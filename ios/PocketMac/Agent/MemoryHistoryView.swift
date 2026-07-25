import SwiftUI
import PocketMacKit

/// One fact the agent has remembered about you or the Mac.
struct MemoryFact: Codable, Identifiable, Equatable {
    let key: String
    let value: String
    let updatedAt: Int

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, value
        case updatedAt = "updated_at_unix"
    }
}

/// One past task and how it ended.
struct TaskSummary: Codable, Identifiable, Equatable {
    let id: String
    let prompt: String
    let status: String
    let createdAt: Int
    let steps: Int
    let outcome: String
}

/// What the agent knows, and what it has done. Two tabs over the same sheet because they answer the
/// same question from different angles — "why did it do that?" is usually memory, "what did it do?"
/// is history.
struct MemoryHistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .memory

    enum Tab: String, CaseIterable, Identifiable {
        case memory = "Memory", history = "History", schedule = "Schedule"
        var id: String { rawValue }
    }

    private var connected: Bool { app.connection.state.isSecured }

    var body: some View {
        NavigationStack {
            VStack(spacing: PM.space.lg) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, PM.space.lg)

                if !connected {
                    empty("Connect to your Mac", "This lives on the Mac, not the phone.")
                } else {
                    switch tab {
                    case .memory: memoryList
                    case .history: historyList
                    case .schedule: ScheduleView()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, PM.space.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(PM.color.background)
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.pmHeadline)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { refresh() }
        .onChange(of: tab) { _, _ in refresh() }
    }

    private func refresh() {
        guard connected else { return }
        switch tab {
        case .memory: app.connection.requestMemory()
        case .history: app.connection.requestHistory()
        case .schedule: app.connection.requestSchedules()
        }
    }

    // MARK: Memory

    private var memoryList: some View {
        ScrollView {
            VStack(spacing: PM.space.md) {
                if app.connection.memory.isEmpty {
                    empty("Nothing remembered yet",
                          "As you work, the agent notes things like where a project lives or which "
                          + "browser you prefer, and uses them on later tasks.")
                } else {
                    PMSection(title: "What it knows",
                              footer: "Swipe a fact away to make it forget. It only remembers what "
                                    + "it decides is durable — never what is merely on screen.") {
                        ForEach(Array(app.connection.memory.enumerated()), id: \.element.key) { i, fact in
                            PMRow(icon: "brain", title: fact.key, subtitle: fact.value,
                                  showsDivider: i < app.connection.memory.count - 1) {
                                Button {
                                    app.connection.forgetMemory(fact.key)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(PM.color.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(PM.space.lg)
        }
    }

    // MARK: History

    private var historyList: some View {
        ScrollView {
            VStack(spacing: PM.space.md) {
                if app.connection.history.isEmpty {
                    empty("No tasks yet", "Every task you run is kept here with how it ended.")
                } else {
                    PMSection(title: "Recent tasks",
                              footer: "Tap a task to run it again.") {
                        ForEach(Array(app.connection.history.enumerated()), id: \.element.id) { i, task in
                            // Re-running is the most common thing you want from history — the same
                            // briefing, the same check — and retyping it from memory was the only
                            // way. The prompt is already here; putting it back in the composer
                            // rather than firing immediately keeps the "read before it touches your
                            // Mac" rule that the dictation path follows.
                            Button {
                                app.connection.agent.draft = task.prompt
                                dismiss()
                            } label: {
                                PMRow(icon: statusIcon(task.status),
                                      iconTint: statusTint(task.status),
                                      title: task.prompt,
                                      subtitle: task.outcome.isEmpty
                                          ? "\(task.steps) steps" : "\(task.steps) steps · \(task.outcome)",
                                      showsDivider: i < app.connection.history.count - 1) {
                                    Text(relative(task.createdAt))
                                        .font(.pmCaption).foregroundStyle(PM.color.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(PM.space.lg)
        }
    }

    private func statusIcon(_ s: String) -> String {
        switch s {
        case "done": "checkmark.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        case "cancelled": "stop.circle"
        case "running": "circle.dotted"
        default: "clock"
        }
    }

    private func statusTint(_ s: String) -> Color {
        switch s {
        case "done": PM.color.success
        case "failed": PM.color.danger
        case "cancelled": PM.color.warning
        default: PM.color.textTertiary
        }
    }

    private func relative(_ unix: Int) -> String {
        guard unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: PM.space.sm) {
            Text(title).font(.pmHeadline).foregroundStyle(PM.color.textSecondary)
            Text(detail).font(.pmCaption).foregroundStyle(PM.color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(PM.space.xl)
        .frame(maxWidth: .infinity)
    }
}
