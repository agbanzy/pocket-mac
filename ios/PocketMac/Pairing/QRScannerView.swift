import SwiftUI
import VisionKit

/// Wraps VisionKit's `DataScannerViewController` to scan the Mac's pairing QR. On the Simulator (no
/// camera) `isSupported`/`isAvailable` are false, so `PairingView` shows the manual / deep-link path
/// instead — the same `PairingPayload` codec, exercised two ways.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    /// Whether live scanning is possible on this device right now (device + permission).
    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        try? scanner.startScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle([item])
        }

        private func handle(_ items: [RecognizedItem]) {
            guard !didScan else { return }
            for case let .barcode(barcode) in items {
                if let value = barcode.payloadStringValue {
                    didScan = true
                    onScan(value)
                    return
                }
            }
        }
    }
}
