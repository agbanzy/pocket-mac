import Foundation
import SwiftUI
import PocketMacKit

/// A deck tile: icon + label + color that fires a `TileAction` when tapped in Run mode. `Codable` so
/// the deck persists across launches.
struct TileModel: Codable, Identifiable, Equatable {
    var id: UUID
    var label: String
    var systemImage: String
    var colorHex: String
    var action: TileActionDTO

    init(id: UUID = UUID(), label: String, systemImage: String, colorHex: String, action: TileActionDTO) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.colorHex = colorHex
        self.action = action
    }

    var color: Color { Color(hex: colorHex) ?? .accentColor }

    /// The kit action frame this tile fires.
    func makeActionFrame() -> ActionFrame {
        ActionFrame(tileID: id, action: action.kitAction)
    }
}

/// Codable mirror of the kit's (non-Codable) `TileAction`. Media/system keys store the raw opcode.
enum TileActionDTO: Codable, Equatable {
    case launchApp(bundleID: String)
    case runShortcut(name: String)
    case mediaKey(UInt8)
    case systemControl(UInt8)

    var kitAction: TileAction {
        switch self {
        case .launchApp(let bundleID): .launchApp(bundleID: bundleID)
        case .runShortcut(let name): .runShortcut(name: name)
        case .mediaKey(let raw): .mediaKey(MediaKey(rawValue: raw) ?? .playPause)
        case .systemControl(let raw): .systemControl(SystemControl(rawValue: raw) ?? .lock)
        }
    }

    static func media(_ key: MediaKey) -> TileActionDTO { .mediaKey(key.rawValue) }
    static func system(_ control: SystemControl) -> TileActionDTO { .systemControl(control.rawValue) }
}

extension Color {
    /// Parses `#RRGGBB` / `#RRGGBBAA` (with or without the leading `#`).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = Double((value & 0xFF00_0000) >> 24) / 255
            g = Double((value & 0x00FF_0000) >> 16) / 255
            b = Double((value & 0x0000_FF00) >> 8) / 255
            a = Double(value & 0x0000_00FF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
