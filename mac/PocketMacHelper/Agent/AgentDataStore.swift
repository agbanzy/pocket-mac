import Foundation
import os

/// Reads what the Rust core persists — remembered facts and task history — so the phone can show
/// them. Deliberately a reader over the same JSON files rather than another FFI entry point: the
/// core already owns the format, and a second writer is how two views of the truth drift apart.
enum AgentDataStore {
    private static let log = Logger(subsystem: "com.innoedge.pocketmac", category: "agent-data")

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PocketMac", isDirectory: true)
    }

    private static var memoryURL: URL { root.appendingPathComponent("memory.json") }
    private static var tasksDir: URL { root.appendingPathComponent("tasks", isDirectory: true) }

    // MARK: Memory

    /// Remembered facts, newest first, as JSON for the phone. Passed through rather than re-encoded
    /// where possible so a field the core adds shows up without a change here.
    static func memoryJSON() -> String {
        guard let data = try? Data(contentsOf: memoryURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return "[]" }
        let sorted = entries.sorted {
            ($0["updated_at_unix"] as? Int ?? 0) > ($1["updated_at_unix"] as? Int ?? 0)
        }
        return encode(sorted)
    }

    /// Drop one fact. The core rewrites this file on its next write, so the shapes must match.
    static func forget(key: String) {
        guard let data = try? Data(contentsOf: memoryURL),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        entries.removeAll { ($0["key"] as? String) == key }
        guard let out = try? JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted)
        else { return }
        do {
            try out.write(to: memoryURL, options: .atomic)
            log.info("forgot memory key")
        } catch {
            log.error("could not update memory: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: History

    /// Recent tasks, newest first. Event lists are dropped — the phone shows a summary, and a full
    /// history with every event would blow past the 64 KB frame payload cap.
    static func historyJSON(limit: Int = 30) -> String {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tasksDir, includingPropertiesForKeys: nil) else { return "[]" }

        var records: [[String: Any]] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let events = obj["events"] as? [[String: Any]] ?? []
            // The final event carries the outcome; that's what a person wants to see in a list.
            let outcome = events.last?["text"] as? String ?? ""
            records.append([
                "id": obj["id"] as? String ?? "",
                "prompt": obj["prompt"] as? String ?? "",
                "status": obj["status"] as? String ?? "unknown",
                "createdAt": obj["created_at_unix"] as? Int ?? 0,
                "steps": events.count,
                "outcome": String(outcome.prefix(180)),
            ])
        }
        records.sort { ($0["createdAt"] as? Int ?? 0) > ($1["createdAt"] as? Int ?? 0) }
        return encode(Array(records.prefix(limit)))
    }

    private static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
