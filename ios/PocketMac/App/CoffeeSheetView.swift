import SwiftUI

/// A gentle, one-time nudge after 5 successful sessions — Pocket Mac is free & open source.
struct CoffeeSheetView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text("☕").font(.system(size: 54))
            Text("Enjoying Pocket Mac?").font(.title2.bold())
            Text("It's free and open source. If it's saved you a trip to your desk, you can buy me a coffee — no pressure at all.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)

            Button {
                if let url = URL(string: "https://buymeacoffee.com/agbanzy") { openURL(url) }
                dismiss()
            } label: {
                Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 1.0, green: 0.87, blue: 0.0))
            .foregroundStyle(.black)

            Button("Maybe later") { dismiss() }
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
