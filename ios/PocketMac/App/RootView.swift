import SwiftUI

/// Top-level shell: the remote surface with toolbar entry points for Devices (discovery) and Pair.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var showDevices = false
    @State private var showPairing = false
    @State private var showSettings = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            RemoteView(showDevices: $showDevices)
                .navigationTitle("Pocket Mac")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showDevices = true
                        } label: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                        .accessibilityLabel("Devices")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showPairing = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                        }
                        .accessibilityLabel("Pair")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
        }
        .sheet(isPresented: $showDevices) { DiscoveryView() }
        .sheet(isPresented: $showPairing) { PairingView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $app.showPairingSheet) { PairingView() }
        .sheet(isPresented: $app.showCoffeeSheet) { CoffeeSheetView() }
        .tint(.accentColor)
        .onAppear { app.start() }
        .onChange(of: app.discovery.services) { _, _ in
            app.pathCoordinator.discoveryChanged() // LAN service appeared/vanished → re-select path
        }
        .onChange(of: app.connection.state.isSecured) { _, secured in
            if secured { app.recordUse() } // count a real session; coffee nudge on the 5th
        }
    }
}
