import SwiftUI

/// Pocket Mac design tokens. The app runs dark-only (`PocketMacApp` forces `.dark`), so these
/// are tuned for a dark surface. One brand accent (the asset `AccentColor`, a purple-blue) plus a
/// small, semantic palette — the single source of truth for color, spacing, radius, and elevation.
/// Use `PM.color`, `PM.space`, `PM.radius` everywhere instead of ad-hoc values.
enum PM {

    // MARK: Color

    enum color {
        /// Brand accent (from the asset catalog so light/dark variants still apply).
        static let accent = Color.accentColor
        static let accentSoft = Color.accentColor.opacity(0.16)
        static let accentHairline = Color.accentColor.opacity(0.35)

        /// Backgrounds, darkest → most elevated.
        static let background = Color(red: 0.05, green: 0.055, blue: 0.075)      // app canvas
        static let surface = Color(red: 0.10, green: 0.11, blue: 0.14)          // cards
        static let surfaceHigh = Color(red: 0.145, green: 0.155, blue: 0.19)    // elevated / pressed

        /// Text.
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.38)

        /// Lines.
        static let hairline = Color.white.opacity(0.10)
        static let hairlineStrong = Color.white.opacity(0.18)

        /// Semantic status.
        static let success = Color(red: 0.30, green: 0.82, blue: 0.55)
        static let warning = Color(red: 0.98, green: 0.74, blue: 0.28)
        static let danger = Color(red: 0.98, green: 0.42, blue: 0.42)
        static let info = Color(red: 0.42, green: 0.68, blue: 0.98)
    }

    // MARK: Spacing (4-pt scale)

    enum space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radius

    enum radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: Elevation (shadow)

    struct Shadow { let color: Color; let radius: CGFloat; let y: CGFloat }
    enum elevation {
        static let card = Shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        static let float = Shadow(color: .black.opacity(0.5), radius: 22, y: 10)
    }
}

extension View {
    func pmShadow(_ s: PM.Shadow) -> some View { shadow(color: s.color, radius: s.radius, y: s.y) }
}
