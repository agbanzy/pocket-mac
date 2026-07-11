import Foundation
import AppKit
import CoreGraphics
import PocketMacKit

/// Runs a decoded ``TileAction``. Prefers unprivileged paths (`NSWorkspace`, media keys, `pmset`,
/// key combos) so the common tiles avoid the per-target-app Automation (AppleEvents) prompt.
struct ActionExecutor {
    enum ActionError: Error { case appNotFound(String), shortcutFailed(Int32) }

    func execute(_ action: TileAction) async throws {
        switch action {
        case .launchApp(let bundleID):
            try await launchApp(bundleID: bundleID)
        case .runShortcut(let name):
            try runShortcut(named: name)
        case .mediaKey(let key):
            MediaKeySender.send(key)
        case .systemControl(let control):
            try systemControl(control)
        }
    }

    // MARK: launchApp — unprivileged

    private func launchApp(bundleID: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ActionError.appNotFound(bundleID)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: runShortcut — `shortcuts run "<name>"`; the Shortcut's own actions may prompt

    private func runShortcut(named name: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ActionError.shortcutFailed(process.terminationStatus)
        }
    }

    // MARK: systemControl

    private func systemControl(_ control: SystemControl) throws {
        switch control {
        case .sleep:
            try run("/usr/bin/pmset", ["sleepnow"])
        case .lock:
            // ⌃⌘Q — lock screen.
            postKeyCombo(keyCode: 0x0C /* Q */, flags: [.maskCommand, .maskControl])
        case .screensaver:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        case .missionControl:
            postKeyCombo(keyCode: 0x7E /* up arrow */, flags: [.maskControl])
        case .showDesktop:
            // F11 (Show Desktop) — depends on the user's keyboard settings.
            postKeyCombo(keyCode: 0x67, flags: [.maskSecondaryFn])
        }
    }

    private func run(_ path: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try process.run()
    }

    private func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}
