import SwiftUI
import PocketMacKit

/// One scheduled task, mirroring the Mac's `schedule.json` entry.
struct Schedule: Codable, Identifiable, Equatable {
    var id: String
    var prompt: String
    var cadence: Cadence
    var enabled: Bool
    var next_run_unix: UInt64
    var last_run_unix: UInt64?
    var last_outcome: String?

    struct Cadence: Codable, Equatable {
        var kind: String            // once | daily | weekdays | every_hours
        var at_unix: UInt64?
        var hour: UInt8?
        var minute: UInt8?
        var hours: UInt8?

        var describe: String {
            switch kind {
            case "daily": String(format: "Every day at %02d:%02d", hour ?? 8, minute ?? 0)
            case "weekdays": String(format: "Weekdays at %02d:%02d", hour ?? 8, minute ?? 0)
            case "every_hours": "Every \(hours ?? 1)h"
            default: "Once"
            }
        }
    }
}

/// Things the Mac does without being asked. Kept intentionally small — a morning briefing, an
/// hourly check — because a scheduler that can express anything becomes a scheduler nobody can read.
struct ScheduleView: View {
    @Environment(AppModel.self) private var app

    @State private var showAdd = false
    @State private var newPrompt = ""
    @State private var cadenceKind = "weekdays"
    @State private var time = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()

    private var schedules: [Schedule] { app.connection.schedules }
    private var connected: Bool { app.connection.state.isSecured }

    var body: some View {
        VStack(spacing: PM.space.md) {
            if !connected {
                Text("Connect to your Mac to set up scheduled tasks.")
                    .font(.pmCaption).foregroundStyle(PM.color.textTertiary)
                    .padding(PM.space.xl)
            } else {
                list
                Button { showAdd = true } label: {
                    Label("Schedule a task", systemImage: "plus")
                }
                .buttonStyle(PMSecondaryButtonStyle())
            }
        }
        .task { if connected { app.connection.requestSchedules() } }
        .onChange(of: connected) { _, up in if up { app.connection.requestSchedules() } }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    private var list: some View {
        Group {
            if schedules.isEmpty {
                VStack(spacing: PM.space.sm) {
                    Text("Nothing scheduled").font(.pmHeadline).foregroundStyle(PM.color.textSecondary)
                    Text("Your Mac can run a task on its own — a morning briefing, an hourly check.")
                        .font(.pmCaption).foregroundStyle(PM.color.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(PM.space.lg)
            } else {
                PMSection(title: "Runs on its own",
                          footer: "These run only while your Mac is awake and the helper is open. "
                                + "A missed window is skipped, never replayed.") {
                    ForEach(Array(schedules.enumerated()), id: \.element.id) { i, s in
                        PMRow(icon: s.enabled ? "clock.fill" : "clock",
                              iconTint: s.enabled ? PM.color.accent : PM.color.textTertiary,
                              title: s.prompt,
                              subtitle: subtitle(for: s),
                              showsDivider: i < schedules.count - 1) {
                            HStack(spacing: PM.space.sm) {
                                Toggle("", isOn: Binding(
                                    get: { s.enabled },
                                    set: { on in
                                        var copy = s; copy.enabled = on
                                        app.connection.setSchedule(copy)
                                    })).labelsHidden().tint(PM.color.accent)
                                Button {
                                    app.connection.removeSchedule(s.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption).foregroundStyle(PM.color.textTertiary)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtitle(for s: Schedule) -> String {
        var parts = [s.cadence.describe]
        if let outcome = s.last_outcome, !outcome.isEmpty {
            parts.append("last: \(outcome.prefix(60))")
        } else {
            parts.append("next \(relative(s.next_run_unix))")
        }
        return parts.joined(separator: " · ")
    }

    private func relative(_ unix: UInt64) -> String {
        guard unix > 0 else { return "—" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unix)), relativeTo: Date())
    }

    private var addSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PM.space.lg) {
                    PMCard {
                        VStack(alignment: .leading, spacing: PM.space.md) {
                            Text("What should it do?").font(.pmHeadline)
                                .foregroundStyle(PM.color.textPrimary)
                            TextEditor(text: $newPrompt)
                                .font(.pmBody).foregroundStyle(PM.color.textPrimary)
                                .scrollContentBackground(.hidden).frame(minHeight: 80)
                                .background(PM.color.surfaceHigh,
                                            in: RoundedRectangle(cornerRadius: PM.radius.sm))
                        }
                    }
                    PMSection(title: "When") {
                        Picker("", selection: $cadenceKind) {
                            Text("Weekdays").tag("weekdays")
                            Text("Every day").tag("daily")
                            Text("Hourly").tag("every_hours")
                        }
                        .pickerStyle(.segmented)
                        .padding(PM.space.md)
                        if cadenceKind != "every_hours" {
                            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                                .padding(.horizontal, PM.space.lg).padding(.bottom, PM.space.md)
                        }
                    }
                    Button {
                        add()
                        showAdd = false
                    } label: { Label("Schedule it", systemImage: "checkmark") }
                    .buttonStyle(PMPrimaryButtonStyle())
                    .disabled(newPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(PM.space.lg)
            }
            .background(PM.color.background)
            .navigationTitle("New schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAdd = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func add() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let cadence = Schedule.Cadence(
            kind: cadenceKind,
            at_unix: nil,
            hour: cadenceKind == "every_hours" ? nil : UInt8(comps.hour ?? 8),
            minute: cadenceKind == "every_hours" ? nil : UInt8(comps.minute ?? 0),
            hours: cadenceKind == "every_hours" ? 1 : nil)
        // next_run of 0 tells the Mac to compute the first run in its own timezone — the phone
        // may well be somewhere else, and a briefing should follow the machine, not the traveller.
        let s = Schedule(id: UUID().uuidString,
                         prompt: newPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                         cadence: cadence, enabled: true, next_run_unix: 0,
                         last_run_unix: nil, last_outcome: nil)
        app.connection.setSchedule(s)
        newPrompt = ""
    }
}
