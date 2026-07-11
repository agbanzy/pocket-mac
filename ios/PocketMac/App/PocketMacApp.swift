import SwiftUI

/// Pocket Mac — the iPhone "remote" that discovers, pairs with, and drives a Mac over an
/// end-to-end-encrypted session. Entry point wiring the app model, the `pocketmac://` deep link, and
/// the root UI.
@main
struct PocketMacApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onOpenURL { url in app.handleIncoming(url: url) }
                .preferredColorScheme(.dark)
        }
    }
}
