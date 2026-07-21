import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import os
import PocketMacKit

/// The on-Mac Claude "computer use" agent. Given a natural-language task from the phone, it loops
/// [screenshot → ask Claude → execute the action on this Mac → repeat] until the task is done,
/// streaming progress back to the phone as `.taskEvent`s.
///
/// Native macOS execution: `screencapture` for stills, `CGEvent` for mouse/keyboard. There is no
/// Swift Anthropic SDK, so the Messages API + computer-use tool is called over raw `URLSession`.
/// Reuses the same Screen Recording + Accessibility grants the remote-control path already needs.
actor AgentRunner {
    private let log = Logger(subsystem: "com.innoedge.pocketmac", category: "agent")
    private let emit: @Sendable (TaskEventKind, String) async -> Void

    private var cancelled = false

    private let model = "claude-opus-4-8"
    private let beta = "computer-use-2025-11-24"
    /// Autonomy budget. Sending a task IS the consent, so the agent runs the job to completion
    /// instead of pausing for step-by-step approval — real multi-app work needs the headroom.
    private let maxIterations = 60

    init(emit: @escaping @Sendable (TaskEventKind, String) async -> Void) {
        self.emit = emit
    }

    /// Abort. This is the one interrupt the user keeps: consent starts the task, Stop ends it.
    func stop() {
        cancelled = true
    }

    /// Kept for wire compatibility with clients that still send a PIN. The PIN gate was removed in
    /// favour of single-consent autonomy, so there is nothing to unblock.
    func providePin(_ pin: String) {}

    // MARK: Run loop

    func run(prompt: String, requirePin: Bool) async {
        cancelled = false
        guard let key = Self.loadAPIKey() else {
            await emit(.error, "No Anthropic API key. Put it in ~/Downloads/medskey.rtf or set ANTHROPIC_API_KEY.")
            return
        }

        // TCC preflight. Without these grants the agent silently does nothing — CGEvents are
        // dropped and captures come back blank — so fail loudly with the exact fix. Note macOS can
        // show the checkbox ticked while still denying: a stale TCC record bound to an older code
        // signature. Removing and re-adding the app (or `tccutil reset`) clears it.
        guard AXIsProcessTrusted() else {
            // Unlike Screen Recording, Accessibility never prompts on its own — an unlisted app just
            // fails silently. Ask for it explicitly so macOS shows the dialog and adds us to the list;
            // the user then only has to flip the switch instead of hunting for “+” and the binary.
            // The literal key, not `kAXTrustedCheckOptionPrompt` — that global is a mutable var and
            // Swift 6 strict concurrency rejects touching it from an actor.
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            await emit(.error, "Accessibility isn't granted — I've asked macOS to show the prompt. "
                + "Open System Settings ▸ Privacy & Security ▸ Accessibility and switch on Pocket Mac "
                + "Helper, then send the task again. (If it's listed with a blank icon, remove it with "
                + "“−” first — that's a stale entry from an older build and it silently blocks control.)")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            await emit(.error, "Screen Recording isn't granted. System Settings ▸ Privacy & Security ▸ "
                + "Screen Recording → enable Pocket Mac Helper, then reopen the app.")
            return
        }

        await emit(.started, prompt)

        // Geometry, measured now (points = logical screen; capture = pixels; model = downscaled).
        guard let firstShot = capture() else { await emit(.error, "Screen capture failed."); return }
        let pt = NSScreen.main?.frame.size ?? CGSize(width: firstShot.px.width, height: firstShot.px.height)
        let model = Self.modelDims(cap: firstShot.px, target: CGSize(width: 1280, height: 800))
        let fx = pt.width / model.width, fy = pt.height / model.height

        let tool: [String: Any] = ["type": "computer_20251124", "name": "computer",
                                   "display_width_px": Int(model.width), "display_height_px": Int(model.height),
                                   "display_number": 1]
        let system = "You are operating a real macOS Mac on the user's behalf via the computer tool. "
            + "Screenshots are \(Int(model.width))x\(Int(model.height)) px; give coordinates in that space. "
            + "macOS uses Command (⌘) for shortcuts, not Control (⌘Space = Spotlight, ⌘Tab = switch apps). "
            + "Work in small steps; after each action take a screenshot and verify. When the task is complete, "
            + "stop and give a one-line summary. If unsure or the task is risky, say so instead of guessing."

        var messages: [[String: Any]] = [[
            "role": "user",
            "content": [["type": "text", "text": prompt],
                        imageBlock(firstShot.pngBase64)],
        ]]

        for iter in 1...maxIterations {
            if cancelled { await emit(.error, "Stopped."); return }
            let resp: [String: Any]
            do { resp = try await callClaude(key: key, tool: tool, system: system, messages: messages) }
            catch { await emit(.error, "Claude request failed: \(error.localizedDescription)"); return }

            let content = resp["content"] as? [[String: Any]] ?? []
            let stop = resp["stop_reason"] as? String ?? ""

            // Narrate any assistant text.
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            if !text.isEmpty { await emit(.thinking, String(text.prefix(240))) }

            messages.append(["role": "assistant", "content": content])

            guard stop == "tool_use" else {
                await emit(.done, text.isEmpty ? "Done." : String(text.prefix(240)))
                return
            }

            var results: [[String: Any]] = []
            for block in content where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String,
                      block["name"] as? String == "computer",
                      let input = block["input"] as? [String: Any] else { continue }
                let action = input["action"] as? String ?? ""

                if cancelled { await emit(.error, "Stopped."); return }

                execute(action: action, input: input, fx: fx, fy: fy)
                // Let the UI settle before the verification screenshot. Without this the next
                // action races the window server — the classic symptom is typed text landing in
                // whatever app stole focus instead of the one just opened.
                try? await Task.sleep(nanoseconds: 350_000_000)
                await emit(.action, describe(action: action, input: input))

                guard let shot = capture() else { results.append(toolResult(id: id, text: "capture failed")); continue }
                results.append(["type": "tool_result", "tool_use_id": id,
                                "content": [["type": "text", "text": "screenshot after \(action)"], imageBlock(shot.pngBase64)]])
            }
            messages.append(["role": "user", "content": results])
            pruneImages(&messages, keep: 3)
            _ = iter
        }
        await emit(.error, "Reached the step limit.")
    }

    // MARK: Anthropic call (raw HTTP)

    /// Retries transient failures (connection drops, 429, 5xx) so a flaky network — a phone
    /// hotspot, a dropped Wi-Fi frame — doesn't kill a task mid-run.
    private func callClaude(key: String, tool: [String: Any], system: String, messages: [[String: Any]]) async throws -> [String: Any] {
        var lastError: Error = NSError(domain: "PocketMac.Agent", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "request failed"])
        for attempt in 1...3 {
            do { return try await callClaudeOnce(key: key, tool: tool, system: system, messages: messages) }
            catch {
                lastError = error
                let ns = error as NSError
                let transient = ns.domain == NSURLErrorDomain || ns.code == 429 || ns.code >= 500
                guard transient, attempt < 3 else { throw error }
                await emit(.thinking, "Network hiccup — retrying (\(attempt)/3)…")
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
        throw lastError
    }

    private func callClaudeOnce(key: String, tool: [String: Any], system: String, messages: [[String: Any]]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 120
        let body: [String: Any] = ["model": model, "max_tokens": 4096, "system": system,
                                   "tools": [tool], "messages": messages]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "PocketMac.Agent", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: String(msg.prefix(300))])
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Screen capture

    private struct Shot { let px: CGSize; let pngBase64: String }

    private func capture() -> Shot? {
        let tmp = NSTemporaryDirectory() + "pmagent-\(UUID().uuidString).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-D", "1", "-t", "png", tmp]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard let img = NSImage(contentsOfFile: tmp),
              let full = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let cap = CGSize(width: full.width, height: full.height)
        let target = Self.modelDims(cap: cap, target: CGSize(width: 1280, height: 800))
        guard let scaled = resize(full, to: target), let b64 = pngBase64(scaled) else { return nil }
        return Shot(px: cap, pngBase64: b64)
    }

    private func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private func pngBase64(_ image: CGImage) -> String? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return data.base64EncodedString()
    }

    private static func modelDims(cap: CGSize, target: CGSize) -> CGSize {
        let f = min(target.width / cap.width, target.height / cap.height, 1)
        return CGSize(width: (cap.width * f).rounded(), height: (cap.height * f).rounded())
    }

    // MARK: Action execution (CGEvent, in logical points, top-left origin)

    private func point(_ coord: [Any]?, fx: CGFloat, fy: CGFloat) -> CGPoint {
        let mx = (coord?.first as? NSNumber)?.doubleValue ?? 0
        let my = (coord?.dropFirst().first as? NSNumber)?.doubleValue ?? 0
        return CGPoint(x: mx * Double(fx), y: my * Double(fy))
    }

    private func execute(action: String, input: [String: Any], fx: CGFloat, fy: CGFloat) {
        let coord = input["coordinate"] as? [Any]
        switch action {
        case "screenshot", "wait", "cursor_position":
            if action == "wait" { Thread.sleep(forTimeInterval: min(3, (input["duration"] as? Double) ?? 1)) }
        case "mouse_move":
            CGWarpMouseCursorPosition(point(coord, fx: fx, fy: fy))
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let p = point(coord, fx: fx, fy: fy)
            let button: CGMouseButton = action == "right_click" ? .right : (action == "middle_click" ? .center : .left)
            let clicks = action == "double_click" ? 2 : (action == "triple_click" ? 3 : 1)
            click(at: p, button: button, clicks: clicks, modifiers: input["text"] as? String)
        case "left_click_drag":
            let start = point(input["start_coordinate"] as? [Any], fx: fx, fy: fy)
            drag(from: start, to: point(coord, fx: fx, fy: fy))
        case "scroll":
            CGWarpMouseCursorPosition(point(coord, fx: fx, fy: fy))
            scroll(direction: input["scroll_direction"] as? String ?? "down", amount: input["scroll_amount"] as? Int ?? 3)
        case "key":
            keyCombo(input["text"] as? String ?? "")
        case "type":
            typeText(input["text"] as? String ?? "")
        case "hold_key":
            keyCombo(input["text"] as? String ?? "")
        default:
            break
        }
    }

    private func click(at p: CGPoint, button: CGMouseButton, clicks: Int, modifiers: String?) {
        let src = CGEventSource(stateID: .hidSystemState)
        let flags = Self.flags(from: modifiers)
        CGWarpMouseCursorPosition(p)
        let downType: CGEventType = button == .right ? .rightMouseDown : (button == .center ? .otherMouseDown : .leftMouseDown)
        let upType: CGEventType = button == .right ? .rightMouseUp : (button == .center ? .otherMouseUp : .leftMouseUp)
        for i in 1...max(1, clicks) {
            for (type, isDown) in [(downType, true), (upType, false)] {
                _ = isDown
                let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.flags = flags
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    private func drag(from a: CGPoint, to b: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: b, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func scroll(direction: String, amount: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        let n = Int32(amount * 3)
        let (dy, dx): (Int32, Int32)
        switch direction {
        case "up": (dy, dx) = (n, 0)
        case "down": (dy, dx) = (-n, 0)
        case "left": (dy, dx) = (0, n)
        case "right": (dy, dx) = (0, -n)
        default: (dy, dx) = (-n, 0)
        }
        CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private func keyCombo(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last else { return }
        let mods = Self.flags(from: parts.dropLast().joined(separator: "+"))
        guard let code = Self.keyCode(last) else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); down?.flags = mods; down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); up?.flags = mods; up?.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var unichars = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: unichars.count, unicodeString: &unichars)
            up?.post(tap: .cghidEventTap)
        }
    }

    private static func flags(from text: String?) -> CGEventFlags {
        var f = CGEventFlags()
        guard let text = text?.lowercased() else { return f }
        if text.contains("cmd") || text.contains("command") || text.contains("super") { f.insert(.maskCommand) }
        if text.contains("shift") { f.insert(.maskShift) }
        if text.contains("ctrl") || text.contains("control") { f.insert(.maskControl) }
        if text.contains("alt") || text.contains("option") { f.insert(.maskAlternate) }
        return f
    }

    private static func keyCode(_ token: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "page_up": 116, "pagedown": 121, "page_down": 121,
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "-": 27, "=": 24, ".": 47, ",": 43, "/": 44, ";": 41, "'": 39, "`": 50,
        ]
        return map[token]
    }

    private func describe(action: String, input: [String: Any]) -> String {
        switch action {
        case "type": return "typed “\(String((input["text"] as? String ?? "").prefix(40)))”"
        case "key": return "pressed \(input["text"] as? String ?? "")"
        case "scroll": return "scrolled \(input["scroll_direction"] as? String ?? "")"
        case "screenshot", "wait": return "\(action)"
        default:
            if let c = input["coordinate"] as? [Any] { return "\(action) at \(c)" }
            return action
        }
    }

    // MARK: Message helpers

    private func imageBlock(_ b64: String) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]]
    }

    private func toolResult(id: String, text: String) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]
    }

    /// Keep only the last `keep` images to bound token cost; older ones become a text stub.
    private func pruneImages(_ messages: inout [[String: Any]], keep: Int) {
        var imagePositions: [(Int, Int, Int)] = []  // (messageIndex, contentIndex, resultIndex or -1)
        for (mi, msg) in messages.enumerated() {
            guard let content = msg["content"] as? [[String: Any]] else { continue }
            for (ci, block) in content.enumerated() {
                if block["type"] as? String == "image" { imagePositions.append((mi, ci, -1)) }
                if block["type"] as? String == "tool_result", let inner = block["content"] as? [[String: Any]] {
                    for (ri, b) in inner.enumerated() where b["type"] as? String == "image" { imagePositions.append((mi, ci, ri)) }
                }
            }
        }
        let drop = max(0, imagePositions.count - keep)
        for (mi, ci, ri) in imagePositions.prefix(drop) {
            guard var content = messages[mi]["content"] as? [[String: Any]] else { continue }
            if ri < 0 {
                content[ci] = ["type": "text", "text": "[screenshot elided]"]
            } else if var inner = content[ci]["content"] as? [[String: Any]] {
                inner[ri] = ["type": "text", "text": "[screenshot elided]"]
                content[ci]["content"] = inner
            }
            messages[mi]["content"] = content
        }
    }

    // MARK: API key

    private static func loadAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], env.hasPrefix("sk-ant-") { return env }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads/medskey.rtf")
        if let raw = try? String(contentsOfFile: path, encoding: .utf8),
           let range = raw.range(of: "sk-ant-[A-Za-z0-9_-]{20,}", options: .regularExpression) {
            return String(raw[range])
        }
        if let stored = UserDefaults.standard.string(forKey: "com.innoedge.pocketmac.anthropicKey"),
           stored.hasPrefix("sk-ant-") { return stored }
        return nil
    }
}
