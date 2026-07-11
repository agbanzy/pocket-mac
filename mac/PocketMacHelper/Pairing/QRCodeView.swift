import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a string (the `pocketmac://pair?…` URL) as a scannable QR code using CoreImage.
struct QRCodeView: View {
    let string: String

    var body: some View {
        Group {
            if let image = Self.generate(from: string) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .accessibilityLabel("Pairing QR code")
    }

    static func generate(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
