import Foundation
import Observation
import PocketMacKit

/// Holds the deck's tiles and persists them to `UserDefaults`. Ships a sensible default deck of live
/// `launchApp` and `mediaKey` tiles.
@MainActor
@Observable
final class DeckStore {
    private(set) var tiles: [TileModel]

    private let defaults: UserDefaults
    private let key = "com.innoedge.pocketmac.deck"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([TileModel].self, from: data) {
            self.tiles = saved
        } else {
            self.tiles = DeckStore.defaultTiles
        }
    }

    /// Fires a tile's action through the connection.
    func fire(_ tile: TileModel, into sink: InputSink) {
        sink.send(.action(tile.makeActionFrame()))
    }

    func add(_ tile: TileModel) {
        tiles.append(tile)
        persist()
    }

    func remove(_ tile: TileModel) {
        tiles.removeAll { $0.id == tile.id }
        persist()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        tiles.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    func reset() {
        tiles = DeckStore.defaultTiles
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tiles) {
            defaults.set(data, forKey: key)
        }
    }

    static let defaultTiles: [TileModel] = [
        .init(label: "Music", systemImage: "music.note", colorHex: "#FC3158", action: .launchApp(bundleID: "com.apple.Music")),
        .init(label: "Safari", systemImage: "safari", colorHex: "#1E8FFF", action: .launchApp(bundleID: "com.apple.Safari")),
        .init(label: "Play/Pause", systemImage: "playpause.fill", colorHex: "#34C759", action: .media(.playPause)),
        .init(label: "Previous", systemImage: "backward.fill", colorHex: "#5E5CE6", action: .media(.previous)),
        .init(label: "Next", systemImage: "forward.fill", colorHex: "#5E5CE6", action: .media(.next)),
        .init(label: "Vol −", systemImage: "speaker.wave.1.fill", colorHex: "#FF9500", action: .media(.volumeDown)),
        .init(label: "Vol +", systemImage: "speaker.wave.3.fill", colorHex: "#FF9500", action: .media(.volumeUp)),
        .init(label: "Mute", systemImage: "speaker.slash.fill", colorHex: "#8E8E93", action: .media(.mute)),
        .init(label: "Mission Control", systemImage: "square.grid.3x3.fill", colorHex: "#30B0C7", action: .system(.missionControl)),
        .init(label: "Lock", systemImage: "lock.fill", colorHex: "#FF375F", action: .system(.lock)),
    ]
}
