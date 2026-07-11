import SwiftUI
import PocketMacKit

/// The main control surface: a persistent connection chip, a segmented switch between the trackpad
/// and the tile deck, and an always-available keyboard bar. Trackpad and deck are separated by the
/// segmented control so pointer touches never collide with tile taps.
struct RemoteView: View {
    @Environment(AppModel.self) private var app
    @Binding var showDevices: Bool
    @State private var surface: Surface = .trackpad

    enum Surface: String, CaseIterable, Identifiable {
        case trackpad = "Trackpad"
        case deck = "Deck"
        var id: String { rawValue }
    }

    private var isSecured: Bool { app.connection.state.isSecured }

    var body: some View {
        VStack(spacing: 12) {
            header

            if app.pairedMac == nil {
                unpairedPrompt
            } else {
                Picker("Surface", selection: $surface) {
                    ForEach(Surface.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Group {
                    switch surface {
                    case .trackpad:
                        TrackpadPanel(sink: app.connection, connected: isSecured)
                    case .deck:
                        TileDeckView(store: app.deck, sink: app.connection, isConnected: isSecured)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                KeyboardBarView { frame in app.connection.send(frame) }
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .disabled(!isSecured)
                    .opacity(isSecured ? 1 : 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ConnectionChip(state: app.connection.state,
                           latencyMS: app.connection.latencyMS,
                           deviceName: app.pairedMac?.displayName,
                           path: app.connection.currentPath)
            Spacer(minLength: 6)
            if app.pairedMac != nil {
                if isSecured {
                    Button("Disconnect") { app.connection.disconnect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Connect") { showDevices = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    // MARK: Unpaired empty state

    private var unpairedPrompt: some View {
        ContentUnavailableView {
            Label("No Mac paired", systemImage: "laptopcomputer.slash")
        } description: {
            Text("Open Pocket Mac on your Mac and scan its QR code — or tap the pair button — to get started.")
        } actions: {
            Button {
                app.showPairingSheet = true
            } label: {
                Label("Pair a Mac", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }
}
