import SwiftUI
import PocketMacKit

/// The menu-bar popover: permission onboarding, pairing (QR + SAS), status, paired-device
/// management, launch-at-login, and quit.
struct MenuBarContentView: View {
    @Bindable var model: HelperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.isAccessibilityTrusted {
                accessibilityOnboarding
            } else if model.isPairing {
                pairingPanel
            } else {
                statusPanel
                pairedDevices
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refreshAccessibility() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pocket Mac").font(.headline)
                Text(model.deviceName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusDot
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(model.isAccessibilityTrusted && model.isAdvertising ? .green : .orange)
            .frame(width: 9, height: 9)
            .help(model.isAdvertising ? "Advertising on your network" : "Not advertising")
    }

    private var accessibilityOnboarding: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility permission needed", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text("Pocket Mac moves the cursor and types for you, which macOS gates behind the Accessibility permission. Grant it, then reopen this menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") { model.requestAccessibility() }
                .buttonStyle(.borderedProminent)
            Button("I’ve granted it — recheck") { model.refreshAccessibility() }
                .buttonStyle(.link)
        }
    }

    private var pairingPanel: some View {
        VStack(spacing: 10) {
            Text("Scan with the Pocket Mac app").font(.subheadline.weight(.semibold))
            if let url = model.activePairingURL {
                QRCodeView(string: url)
                    .frame(width: 180, height: 180)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
            if let sas = model.activeSAS {
                VStack(spacing: 2) {
                    Text("Confirm this code matches your phone").font(.caption2).foregroundStyle(.secondary)
                    Text(sas).font(.system(.title2, design: .monospaced)).tracking(4)
                }
            }
            Button("Cancel pairing") { model.stopPairing() }
                .buttonStyle(.bordered)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.isAdvertising ? "Discoverable on this network" : "Not advertising",
                  systemImage: model.isAdvertising ? "wifi" : "wifi.slash")
                .font(.subheadline)
            Button {
                model.startPairing()
            } label: {
                Label("Pair New Device", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var pairedDevices: some View {
        let devices = model.pairedDevices
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Paired devices").font(.caption).foregroundStyle(.secondary)
                ForEach(devices, id: \.peerID) { device in
                    HStack {
                        Image(systemName: device.isRevoked ? "iphone.slash" : "iphone")
                            .foregroundStyle(device.isRevoked ? .secondary : .primary)
                        Text(device.displayName).font(.callout)
                        Spacer()
                        if !device.isRevoked {
                            Button("Revoke") { model.revoke(device.peerID) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .font(.callout)

            if let error = model.lastError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }

            Button("Quit Pocket Mac") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
    }
}
