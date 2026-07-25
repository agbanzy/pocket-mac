import Foundation
import Observation
import PocketMacKit

/// The phone-side state of an AI "Ask" task: the running flag, the streamed progress log, and any
/// pending PIN prompt. Driven by `.taskEvent` control frames arriving over the connection.
@MainActor
@Observable
final class AgentSession {
    struct Event: Identifiable {
        let id = UUID()
        let kind: TaskEventKind
        let text: String
    }

    private(set) var events: [Event] = []
    var isRunning = false
    var pendingPinReason: String?

    /// What the user has typed but not yet run.
    ///
    /// It lives here rather than in `AskView` because the tab strip swaps view identity: SwiftUI
    /// tears the old surface down, taking its `@State` with it. Typing a long task, tapping Screen
    /// to glance at the Mac, and coming back used to lose every word of it. The session outlives the
    /// tabs, so the draft does too.
    var draft = ""

    func reset() {
        events = []
        isRunning = false
        pendingPinReason = nil
    }

    func append(kind: TaskEventKind, text: String) {
        events.append(Event(kind: kind, text: text))
        switch kind {
        case .started: isRunning = true
        case .needsPin: pendingPinReason = text
        case .done, .error: isRunning = false; pendingPinReason = nil
        default: break
        }
    }
}
