import Foundation
import ServiceManagement

/// Registers the helper to launch at login via `SMAppService` (macOS 13+).
///
/// It registers as a **login item / LaunchAgent in the user's Aqua session** — never a
/// `LaunchDaemon`. A root/pre-login daemon runs outside the GUI session and physically cannot post
/// session `CGEvent`s or hold the user's Accessibility grant, so it could never do this job.
enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
