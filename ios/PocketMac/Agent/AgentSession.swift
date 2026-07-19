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
