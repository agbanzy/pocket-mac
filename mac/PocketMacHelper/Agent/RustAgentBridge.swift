import Foundation
import os
import PocketMacKit

/// Swift front door to the shared Rust agent (`agent-core` via the `pm_agent_*` C ABI).
///
/// Why this exists: the same brain — agent loop, Claude client with prompt caching, MCP tool
/// registry, durable task history — runs unchanged on macOS, Windows, and Android. Wiring the
/// helper to it means the Mac app inherits MCP tools and persisted task history, and every fix
/// lands once instead of three times.
///
/// Threading: `pm_agent_run` blocks its thread and calls back from a Rust worker, so the call runs
/// on a detached background thread. Events are funnelled through an `AsyncStream` and re-emitted in
/// order on the consuming task — spawning a `Task` per callback would let progress lines interleave.
enum RustAgentBridge {
    private static let log = Logger(subsystem: "com.innoedge.pocketmac", category: "rust-agent")

    /// The assistant's voice. Kept short on purpose: it rides in the cached prompt prefix on every
    /// turn, and long personas crowd out the screenshots the model actually reasons over. Override
    /// with `defaults write com.innoedge.pocketmac.helper persona '<text>'`.
    static var persona: String {
        UserDefaults.standard.string(forKey: "persona") ?? """
        You are Jarvis, the user's personal computer assistant. Be composed, precise, and dry — a \
        capable colleague, not a cheerful chatbot. Narrate only what matters: say what you are about \
        to do, then what happened. No filler, no apologies, no restating the request. Address the \
        user directly. If a task is ambiguous or risky, say so in one sentence and ask rather than \
        guess. Finish with a single line stating the outcome.
        """
    }

    /// Where durable task history lives, so a controller can list past runs.
    static var storeDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PocketMac/tasks", isDirectory: true).path
    }

    /// Carries the stream continuation across the C boundary. `ctx` is an opaque pointer to this.
    private final class EventSink {
        let yield: @Sendable (TaskEventKind, String) -> Void
        init(yield: @escaping @Sendable (TaskEventKind, String) -> Void) { self.yield = yield }
    }

    /// Ferries the opaque `ctx` pointer into the detached thread. Raw pointers aren't `Sendable`;
    /// this one is safe by construction — the sink is retained until `pm_agent_run` returns, and
    /// only the C callback dereferences it.
    private struct SinkHandle: @unchecked Sendable {
        let raw: UnsafeMutableRawPointer
    }

    private static func kind(from raw: String) -> TaskEventKind {
        switch raw {
        case "started": .started
        case "action": .action
        case "done": .done
        case "error": .error
        default: .thinking     // unknown kinds degrade rather than drop the event
        }
    }

    /// C-compatible trampoline. Must not capture context, hence the `ctx` pointer.
    private static let callback: @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
    ) -> Void = { kindPtr, textPtr, ctx in
        guard let ctx else { return }
        let sink = Unmanaged<EventSink>.fromOpaque(ctx).takeUnretainedValue()
        let rawKind = kindPtr.map { String(cString: $0) } ?? "thinking"
        let text = textPtr.map { String(cString: $0) } ?? ""
        sink.yield(kind(from: rawKind), text)
    }

    /// `pm_agent_run` returned before the loop could start (3 backend, 4 task store, 5 runtime), so
    /// nothing was reported to the user and a fallback runner can still serve the task. Contrast rc
    /// 1, where the loop ran and already streamed its own failure.
    static func isStartupFailure(_ rc: Int32) -> Bool { rc >= 3 }

    /// Run a task on the Rust core, streaming progress through `emit` in order. Returns the C
    /// status code when the task finishes, fails, or is cancelled.
    @discardableResult
    static func run(
        prompt: String,
        apiKey: String,
        persona: String?,
        emit: @escaping @Sendable (TaskEventKind, String) async -> Void
    ) async -> Int32 {
        let (stream, continuation) = AsyncStream<(TaskEventKind, String)>.makeStream()

        // Re-emit in arrival order; finishes when the run completes and the continuation closes.
        let pump = Task {
            for await (kind, text) in stream {
                await emit(kind, text)
            }
        }

        let sink = EventSink { kind, text in continuation.yield((kind, text)) }
        // Hand the C side a plain opaque pointer: `Unmanaged` isn't Sendable, a raw pointer is.
        // Retained here, released once `pm_agent_run` has returned and can no longer call back.
        let handle = SinkHandle(raw: Unmanaged.passRetained(sink).toOpaque())
        let storeDir = storeDirectory

        let code: Int32 = await withCheckedContinuation { resume in
            Thread.detachNewThread {
                let rc = prompt.withCString { p in
                    apiKey.withCString { k in
                        storeDir.withCString { s in
                            if let persona {
                                return persona.withCString { pe in
                                    pm_agent_run(p, k, s, pe, callback, handle.raw)
                                }
                            }
                            return pm_agent_run(p, k, s, nil, callback, handle.raw)
                        }
                    }
                }
                resume.resume(returning: rc)
            }
        }

        continuation.finish()
        Unmanaged<EventSink>.fromOpaque(handle.raw).release()
        await pump.value

        if code != 0 {
            let detail = pm_agent_last_error().map { String(cString: $0) } ?? "unknown error"
            log.error("rust agent failed rc=\(code) detail=\(detail, privacy: .public)")
            // rc 1: the loop already reported its own failure. Startup failures stay silent so the
            // caller can fall back without the user seeing a spurious error first.
            if code == 2 { await emit(.error, detail) }
        }
        return code
    }

    /// Ask the in-flight task to stop at the next step boundary.
    static func cancel() {
        pm_agent_cancel()
    }
}
