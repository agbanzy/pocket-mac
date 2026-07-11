import SwiftUI
import PocketMacKit

/// Pairing flow: scan the Mac's QR (device) or paste/deep-link the `pocketmac://pair?…` URL
/// (Simulator), then confirm the 6-digit SAS matches the number shown on the Mac before the pairing
/// is persisted. The SAS is bound into the handshake prologue, so a mismatch also fails cryptographically.
struct PairingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var manualURL = ""
    @State private var errorText: String?
    @State private var showScanner = false
    @State private var justPaired = false

    var body: some View {
        NavigationStack {
            Group {
                if justPaired {
                    successView
                } else if let payload = app.pendingPairing {
                    sasConfirmation(payload)
                } else {
                    pairingOptions
                }
            }
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        app.cancelPairing()
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            scannerSheet
        }
    }

    // MARK: Options (scan / manual)

    private var pairingOptions: some View {
        Form {
            if let existing = app.pairedMac {
                Section("Currently paired") {
                    LabeledContent("Mac", value: existing.displayName)
                    LabeledContent("Fingerprint", value: existing.peerID.fingerprint)
                    Button(role: .destructive) {
                        app.unpair()
                    } label: {
                        Label("Unpair this Mac", systemImage: "trash")
                    }
                }
            }

            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                .disabled(!QRScannerView.isAvailable)
            } header: {
                Text("Scan")
            } footer: {
                Text(QRScannerView.isAvailable
                     ? "Point the camera at the QR code shown by Pocket Mac on your Mac."
                     : "Camera scanning isn't available on this device (e.g. the Simulator). Use the pairing link below.")
            }

            Section {
                TextField("pocketmac://pair?…", text: $manualURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .lineLimit(1...4)
                Button {
                    submitManual()
                } label: {
                    Label("Continue", systemImage: "arrow.right.circle.fill")
                }
                .disabled(manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Pairing link")
            } footer: {
                Text("On the Mac, choose “Copy pairing link” and paste it here. This device's identity is \(app.deviceFingerprint).")
            }
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            ZStack {
                if QRScannerView.isAvailable {
                    QRScannerView { scanned in
                        showScanner = false
                        ingest(scanned)
                    }
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera unavailable",
                                           systemImage: "camera.fill",
                                           description: Text("Use the pairing link instead."))
                }
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showScanner = false }
                }
            }
        }
    }

    // MARK: SAS confirmation

    private func sasConfirmation(_ payload: PairingPayload) -> some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text(payload.deviceName)
                    .font(.title2.weight(.semibold))
                Text("Confirm this code matches the one on your Mac")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(formattedSAS(payload.sas))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
                .tracking(6)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)

            LabeledContent("Mac fingerprint", value: payload.macPeerID.fingerprint)
                .font(.footnote)
                .padding(.horizontal)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    app.confirmPairing(payload)
                    justPaired = true
                } label: {
                    Text("Codes match — Pair")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .cancel) {
                    app.cancelPairing()
                } label: {
                    Text("They don't match")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    // MARK: Success

    private var successView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("Paired")
                .font(.title.weight(.bold))
            Text("You can now connect from Devices and drive your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
        }
    }

    // MARK: Actions

    private func submitManual() {
        ingest(manualURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func ingest(_ string: String) {
        do {
            let payload = try PairingPayload(urlString: string)
            errorText = nil
            manualURL = ""
            app.stagePairing(payload)
        } catch {
            errorText = "That isn't a valid Pocket Mac pairing link."
        }
    }

    private func formattedSAS(_ sas: String) -> String {
        guard sas.count == 6 else { return sas }
        let mid = sas.index(sas.startIndex, offsetBy: 3)
        return "\(sas[sas.startIndex..<mid]) \(sas[mid...])"
    }
}
