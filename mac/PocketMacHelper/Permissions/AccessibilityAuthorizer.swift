import Foundation
import AppKit
import ApplicationServices

/// Gates the one permission the helper needs: **Accessibility** (`kTCCServiceAccessibility`).
///
/// A pure event *sender* needs only Accessibility — NOT Input Monitoring (which is for *reading*
/// the event stream). The grant cannot be set programmatically; the system dialog is the only path,
/// and the grant is bound to the signed binary identity, so a stable signing cert keeps it across
/// rebuilds. Without it, `CGEventPost` silently no-ops.
enum AccessibilityAuthorizer {
    /// Whether the process is currently a trusted Accessibility client.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Checks trust and, if untrusted, shows the system prompt. Returns the current trust state.
    @discardableResult
    static func promptIfNeeded() -> Bool {
        // Use the documented key string directly — the imported `kAXTrustedCheckOptionPrompt`
        // global is a mutable `var` that Swift 6 (correctly) flags as not concurrency-safe.
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Deep-links straight to the Accessibility pane of System Settings.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
