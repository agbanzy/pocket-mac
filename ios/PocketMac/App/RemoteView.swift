import SwiftUI
import PocketMacKit

/// The main control surface: a persistent connection chip, a segmented switch between the trackpad
/// and the tile deck, and an always-available keyboard bar. Trackpad and deck are separated by the
/// segmented control so pointer touches never collide with tile taps.
struct RemoteView: View {
    @Environment(AppModel.self) private var app
    @Binding var showDevices: Bool
    @State private var surface: Surface = .trackpad
    @State private var keyboardActive = false
    @State private var lastScrollY: CGFloat = 0
    @State private var floatExpanded = false

    enum Surface: String, CaseIterable, Identifiable {
        case screen = "Screen"
        case trackpad = "Trackpad"
        case deck = "Deck"
        var id: String { rawValue }
    }

    private var isSecured: Bool { app.connection.state.isSecured }

    var body: some View {
        Group {
            if app.pairedMac == nil {
                VStack(spacing: 12) { header; unpairedPrompt }
            } else if surface == .screen {
                screenLayout          // full-bleed remote desktop
            } else {
                controlLayout         // trackpad / deck with normal chrome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface == .screen && app.pairedMac != nil ? Color.black : Color(.systemGroupedBackground))
    }

    /// The Screen tab: the Mac fills the whole phone (great in landscape), with an AssistiveTouch-style
    /// draggable circular control (tap to expand into the switcher + keyboard + status).
    private var screenLayout: some View {
        ScreenModeView(connection: app.connection, connected: isSecured)
            .ignoresSafeArea()
            .overlay {
                FloatingControl(expanded: $floatExpanded, statusTint: app.connection.state.tint) {
                    floatPanel
                }
            }
            .overlay(alignment: .trailing) { scrollStrip }
            .background(
                // Hidden field: focusing it pops the iOS keyboard; keystrokes stream to the Mac.
                HiddenKeyboardField(isActive: $keyboardActive) { app.connection.send($0) }
                    .frame(width: 1, height: 1).opacity(0.01)
            )
            .statusBarHidden()
    }

    /// The contents shown when the floating control is expanded (the FloatingControl supplies the card).
    private var floatPanel: some View {
        VStack(spacing: 12) {
            Picker("Surface", selection: $surface) {
                ForEach(Surface.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            HStack(spacing: 16) {
                Button { keyboardActive.toggle() } label: {
                    Image(systemName: keyboardActive ? "keyboard.chevron.compact.down.fill" : "keyboard")
                        .foregroundStyle(keyboardActive ? Color.accentColor : .white)
                }
                Circle().fill(app.connection.state.tint).frame(width: 9, height: 9)
                if let ms = app.connection.latencyMS {
                    Text("\(ms)ms").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

    /// A dedicated scroll rail on the right edge — drag up/down to scroll the focused Mac app.
    private var scrollStrip: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.ultraThinMaterial)
            .frame(width: 30)
            .overlay(Image(systemName: "arrow.up.arrow.down").font(.caption2).foregroundStyle(.white.opacity(0.6)))
            .padding(.vertical, 70)
            .padding(.trailing, 4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let delta = value.translation.height - lastScrollY
                        lastScrollY = value.translation.height
                        let dy = Int16(clamping: Int(delta * 2))
                        if dy != 0 { app.connection.send(.input(.scroll(dx: 0, dy: dy))) }
                    }
                    .onEnded { _ in lastScrollY = 0 }
            )
    }

    private var controlLayout: some View {
        VStack(spacing: 12) {
            header
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
                case .screen:
                    EmptyView()
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
