import SwiftUI

/// UI vocabulary for the realized connection path — surfaced in the chip and Settings so the
/// same-Wi‑Fi ("direct") vs relay ("anywhere") distinction is always visible to the user.
extension ConnectionPath {
    var isLAN: Bool { self == .lan }
    var shortLabel: String { self == .lan ? "Same Wi‑Fi" : "Anywhere" }
    var friendly: String { self == .lan ? "Same Wi‑Fi (direct)" : "Anywhere (relay)" }
    var glyph: String { self == .lan ? "wifi" : "globe" }
    var tint: Color { self == .lan ? PM.color.success : PM.color.info }
}

extension Optional where Wrapped == ConnectionPath {
    var isLAN: Bool { self == .lan }
    var friendly: String { self?.friendly ?? "Not connected" }
    var shortLabel: String { self?.shortLabel ?? "—" }
    var glyph: String { self?.glyph ?? "bolt.horizontal.circle" }
}
