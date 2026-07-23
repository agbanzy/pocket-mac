import SwiftUI
import PocketMacKit

/// The home hub. A connection hero card, a custom mode switcher (Ask / Screen / Trackpad / Deck),
/// and the selected surface below. Ask — the natural-language agent — is the hero and the default.
/// Screen takes over full-bleed for landscape remote-desktop use; everything else lives in the hub.
struct RemoteView: View {
    @Environment(AppModel.self) private var app
    @Binding var showDevices: Bool
    @State private var surface: Surface = .ask
    @State private var keyboardActive = false
    @State private var lastScrollY: CGFloat = 0
    @State private var floatExpanded = false

    enum Surface: String, CaseIterable, Identifiable {
        case ask = "Ask", screen = "Screen", trackpad = "Trackpad", deck = "Deck"
        var id: String { rawValue }
        var glyph: String {
            switch self {
            case .ask: "sparkles"
            case .screen: "display"
            case .trackpad: "cursorarrow.rays"
            case .deck: "square.grid.2x2"
            }
        }
    }

    private var isSecured: Bool { app.connection.state.isSecured }

    var body: some View {
        Group {
            if app.pairedMac == nil {
                onboarding
            } else if surface == .screen {
                screenLayout
            } else {
                hub
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface == .screen && app.pairedMac != nil ? Color.black : PM.color.background)
    }

    // MARK: Hub

    private var hub: some View {
        VStack(spacing: PM.space.lg) {
            connectionHero
            modeSwitcher
            selectedSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if surface == .trackpad || surface == .deck {
                KeyboardBarView { frame in app.connection.send(frame) }
                    .disabled(!isSecured)
                    .opacity(isSecured ? 1 : 0.5)
            }
        }
        .padding(PM.space.lg)
    }

    @ViewBuilder private var selectedSurface: some View {
        switch surface {
        case .ask: AskView()
        case .trackpad: TrackpadPanel(sink: app.connection, connected: isSecured)
        case .deck: TileDeckView(store: app.deck, sink: app.connection, isConnected: isSecured)
        case .screen: EmptyView()
        }
    }

    /// The live link, front and center: device, path (Same Wi‑Fi / Anywhere), latency, connect toggle.
    private var connectionHero: some View {
        HStack(spacing: PM.space.md) {
            ZStack {
                Circle().fill(app.connection.state.tint.opacity(0.18)).frame(width: 46, height: 46)
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(app.connection.state.tint)
                PMStatusDot(tint: app.connection.state.tint, pulsing: app.connection.state.isBusy)
                    .offset(x: 16, y: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.pairedMac?.displayName ?? "Mac")
                    .font(.pmHeadline).foregroundStyle(PM.color.textPrimary)
                HStack(spacing: 5) {
                    Image(systemName: isSecured ? app.connection.currentPath.glyph : "bolt.horizontal.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(isSecured ? app.connection.currentPath.friendly : app.connection.state.label)
                    if isSecured, let ms = app.connection.latencyMS {
                        Text("· \(ms) ms").monospacedDigit()
                    }
                }
                .font(.pmCaption).foregroundStyle(PM.color.textSecondary).lineLimit(1)
            }
            Spacer(minLength: PM.space.sm)
            Button(isSecured ? "Disconnect" : "Connect") {
                if isSecured { app.connection.disconnect() } else { showDevices = true }
            }
            .font(.pmCaption.weight(.semibold))
            .foregroundStyle(isSecured ? PM.color.textSecondary : PM.color.accent)
            .padding(.horizontal, PM.space.md).padding(.vertical, PM.space.sm)
            .background(isSecured ? PM.color.surfaceHigh : PM.color.accentSoft, in: Capsule())
        }
        .padding(PM.space.md)
        .background(PM.color.surface, in: RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous)
            .strokeBorder(PM.color.hairline, lineWidth: 1))
        .animation(.snappy, value: app.connection.state)
    }

    /// Custom mode switcher — four cards, the active one filled with the brand accent.
    private var modeSwitcher: some View {
        HStack(spacing: PM.space.sm) {
            ForEach(Surface.allCases) { mode in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { surface = mode }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: mode.glyph).font(.system(size: 18, weight: .semibold))
                        Text(mode.rawValue).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, PM.space.md)
                    .foregroundStyle(surface == mode ? .white : PM.color.textSecondary)
                    .background(surface == mode ? PM.color.accent : PM.color.surface,
                                in: RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous)
                        .strokeBorder(surface == mode ? Color.clear : PM.color.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Screen (full-bleed remote desktop)

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
                HiddenKeyboardField(isActive: $keyboardActive) { app.connection.send($0) }
                    .frame(width: 1, height: 1).opacity(0.01)
            )
            .statusBarHidden()
    }

    private var floatPanel: some View {
        VStack(spacing: 12) {
            Picker("Surface", selection: $surface) {
                ForEach(Surface.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            HStack(spacing: 16) {
                Button { keyboardActive.toggle() } label: {
                    Image(systemName: keyboardActive ? "keyboard.chevron.compact.down.fill" : "keyboard")
                        .foregroundStyle(keyboardActive ? Color.accentColor : .white)
                }
                PMStatusDot(tint: app.connection.state.tint, pulsing: app.connection.state.isBusy)
                if let ms = app.connection.latencyMS {
                    Text("\(ms)ms").font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

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

    // MARK: Onboarding (unpaired)

    private var onboarding: some View {
        VStack(spacing: PM.space.xl) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(PM.color.accentSoft)
                    .frame(width: 112, height: 112)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(PM.color.accent)
            }
            VStack(spacing: PM.space.sm) {
                Text("Pocket Mac").font(.pmDisplay).foregroundStyle(PM.color.textPrimary)
                Text("Your Mac, in your pocket — see it, touch it, or just ask it to do things.")
                    .font(.pmBody).foregroundStyle(PM.color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PM.space.xl)
            }
            Spacer()
            Button { app.showPairingSheet = true } label: {
                Label("Pair your Mac", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(PMPrimaryButtonStyle())
            .padding(.horizontal, PM.space.xl)
            .padding(.bottom, PM.space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
