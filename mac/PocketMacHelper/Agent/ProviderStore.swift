import Foundation
import os

/// Which model backs the agent, chosen from the phone.
///
/// The choice is written to `provider.json` beside the task store, which is exactly where the Rust
/// core reads it. That keeps the C ABI unchanged as providers come and go: adding one is a new row
/// in this table, not a new function parameter.
enum ProviderStore {
    private static let log = Logger(subsystem: "com.innoedge.pocketmac", category: "provider")

    struct Option: Codable {
        let id: String
        let name: String
        let detail: String
        /// False when this Mac cannot use it right now, so the phone can grey it out and say why.
        let available: Bool
        /// True when the provider needs an API key the user must supply.
        let needsKey: Bool
    }

    static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PocketMac/provider.json")
    }

    /// What this Mac can actually run, checked rather than assumed — offering a provider that then
    /// fails at task time is worse than not offering it.
    static func options() -> [Option] {
        let hasClaudeCode = claudeCodeInstalled()
        let hasAPIKey = AgentRunner.loadAPIKey() != nil
        return [
            Option(id: "claude-code", name: "Claude subscription",
                   detail: hasClaudeCode ? "Uses Claude Code on this Mac — no API key"
                                         : "Claude Code isn’t installed on this Mac",
                   available: hasClaudeCode, needsKey: false),
            Option(id: "claude", name: "Claude API",
                   detail: hasAPIKey ? "Fastest — native tool use" : "No API key found on this Mac",
                   available: hasAPIKey, needsKey: true),
            Option(id: "grok", name: "Grok 4.5",
                   detail: "xAI — needs XAI_API_KEY",
                   available: true, needsKey: true),
            Option(id: "ollama", name: "Local model",
                   detail: localServerRunning() ? "Ollama is running on this Mac"
                                                : "Start Ollama with a vision model",
                   available: localServerRunning(), needsKey: false),
        ]
    }

    static func activeId() -> String {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["provider"] as? String else { return "claude" }
        return id
    }

    static func setActive(id: String, model: String) {
        var obj: [String: Any] = ["provider": id]
        if !model.isEmpty { obj["model"] = model }
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
            try data.write(to: configURL, options: .atomic)
            log.info("provider set to \(id, privacy: .public)")
        } catch {
            log.error("could not save provider: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// JSON the phone renders as a list. One string field keeps the wire payload stable.
    static func availableJSON() -> String {
        (try? JSONEncoder().encode(options())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    // MARK: Probes

    private static func claudeCodeInstalled() -> Bool {
        // `which` via a login shell, because the helper's PATH does not include Homebrew.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-lc", "command -v claude >/dev/null 2>&1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    private static func localServerRunning() -> Bool {
        // A TCP connect to Ollama's port is enough, and far cheaper than an HTTP round trip.
        guard let url = URL(string: "http://127.0.0.1:11434/v1/models") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.4
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 0.6)
        return ok
    }
}
