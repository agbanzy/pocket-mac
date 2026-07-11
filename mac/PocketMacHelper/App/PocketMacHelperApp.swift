import SwiftUI

/// The menu-bar helper entry point. `LSUIElement` (set in Info.plist) keeps it out of the Dock; it
/// lives entirely in a `MenuBarExtra`. Runs in the Aqua user session — the context CGEvent posting
/// and TCC prompts require.
@main
struct PocketMacHelperApp: App {
    @State private var model = HelperModel.shared

    init() {
        // App.init runs on the main actor; bring the helper up (identity, advertising) at launch.
        HelperModel.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("Pocket Mac", systemImage: "iphone.gen3") {
            MenuBarContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
