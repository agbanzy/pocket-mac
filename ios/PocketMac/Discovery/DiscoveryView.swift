import SwiftUI
import PocketMacKit

/// Lists Pocket Mac helpers found on the LAN and connects to the paired one. Surfaces the Local
/// Network permission-denied state with a jump to Settings.
struct DiscoveryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var connectingID: DiscoveredService.ID?

    var body: some View {
        NavigationStack {
            List {
                if app.discovery.permissionDenied {
                    permissionDeniedSection
                }

                Section {
                    if app.discovery.services.isEmpty {
                        searchingRow
                    } else {
                        ForEach(app.discovery.services) { service in
                            serviceRow(service)
                        }
                    }
                } header: {
                    Text("Macs on this network")
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { app.discovery.start() }
            .onDisappear { app.discovery.stop() }
        }
    }

    private var footerText: String {
        if let mac = app.pairedMac {
            return "Paired with \(mac.displayName). Only your paired Mac will accept the connection."
        }
        return "Pair with a Mac first (QR / pair button), then connect to it here."
    }

    private var searchingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(app.discovery.permissionDenied ? "Local Network access is off." : "Searching for Macs…")
                .foregroundStyle(.secondary)
        }
    }

    private func serviceRow(_ service: DiscoveredService) -> some View {
        let isPaired = app.pairedMac != nil
        return HStack {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.body.weight(.medium))
                Text("Available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if connectingID == service.id {
                ProgressView()
            } else {
                Button("Connect") { connect(to: service) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!isPaired)
            }
        }
    }

    private var permissionDeniedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Local Network is off", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                Text("Pocket Mac needs Local Network access to find your Mac. Enable it in Settings, then return here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }

    private func connect(to service: DiscoveredService) {
        connectingID = service.id
        Task {
            await app.connect(to: service)
            connectingID = nil
            if app.connection.state.isSecured { dismiss() }
        }
    }
}
