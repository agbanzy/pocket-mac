import SwiftUI
import PocketMacKit

/// A single-page grid of action tiles. An explicit Run vs Edit mode guarantees that rearranging or
/// deleting tiles never fires an action: taps only dispatch in Run mode.
struct TileDeckView: View {
    let store: DeckStore
    let sink: InputSink
    let isConnected: Bool

    @State private var editing = false
    @State private var firedTileID: UUID?
    @State private var showAdd = false

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 12)]

    var body: some View {
        VStack(spacing: 10) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.tiles) { tile in
                        TileButton(
                            tile: tile,
                            editing: editing,
                            fired: firedTileID == tile.id,
                            enabled: isConnected && !editing,
                            onTap: { fire(tile) },
                            onDelete: { store.remove(tile) }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .animation(.snappy, value: store.tiles)
            }
        }
        .confirmationDialog("Add a tile", isPresented: $showAdd, titleVisibility: .visible) {
            ForEach(Self.addable, id: \.label) { preset in
                Button(preset.label) { store.add(preset) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text(editing ? "Edit deck" : "Deck")
                .font(.headline)
            Spacer()
            if editing {
                Button { showAdd = true } label: { Image(systemName: "plus.circle.fill") }
                Button("Reset") { store.reset() }
                    .font(.subheadline)
            }
            Button(editing ? "Done" : "Edit") {
                withAnimation(.snappy) { editing.toggle() }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal)
    }

    private func fire(_ tile: TileModel) {
        guard !editing, isConnected else { return }
        store.fire(tile, into: sink)
        firedTileID = tile.id
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if firedTileID == tile.id { firedTileID = nil }
        }
    }

    /// Presets offered by the "add tile" dialog in Edit mode.
    static let addable: [TileModel] = [
        .init(label: "Sleep", systemImage: "moon.zzz.fill", colorHex: "#5E5CE6", action: .system(.sleep)),
        .init(label: "Screensaver", systemImage: "sparkles", colorHex: "#30B0C7", action: .system(.screensaver)),
        .init(label: "Show Desktop", systemImage: "menubar.dock.rectangle", colorHex: "#8E8E93", action: .system(.showDesktop)),
        .init(label: "Brightness +", systemImage: "sun.max.fill", colorHex: "#FF9500", action: .media(.brightnessUp)),
        .init(label: "Brightness −", systemImage: "sun.min.fill", colorHex: "#FFB340", action: .media(.brightnessDown)),
        .init(label: "Notes", systemImage: "note.text", colorHex: "#FFCC00", action: .launchApp(bundleID: "com.apple.Notes")),
    ]
}

/// One tile. Renders a colored card; in Edit mode it wiggles and shows a delete badge, and taps are
/// routed to the mode-appropriate handler by the parent (fire in Run, no-op in Edit).
private struct TileButton: View {
    let tile: TileModel
    let editing: Bool
    let fired: Bool
    let enabled: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: tile.systemImage)
                    .font(.system(size: 26, weight: .semibold))
                Text(tile.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(tile.color.gradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .opacity(enabled || editing ? 1 : 0.45)
            .scaleEffect(fired ? 0.94 : 1)
            .animation(.spring(duration: 0.18), value: fired)
        }
        .buttonStyle(.plain)
        .disabled(editing) // in Edit mode the card itself is inert; only the delete badge acts
        .overlay(alignment: .topTrailing) {
            if editing {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .offset(x: 6, y: -6)
                .transition(.scale)
            }
        }
        .rotationEffect(.degrees(editing ? -1.2 : 0))
        .animation(editing ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true) : .default,
                   value: editing)
    }
}
