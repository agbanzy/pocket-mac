import SwiftUI

/// Pocket Mac type scale. System fonts (SF Pro) with a consistent set of roles so every screen
/// shares the same rhythm. `.rounded` on display roles gives the friendly, native-but-branded feel.
extension Font {
    static let pmDisplay = Font.system(size: 28, weight: .bold, design: .rounded)
    static let pmTitle = Font.system(size: 22, weight: .bold, design: .rounded)
    static let pmHeadline = Font.system(size: 17, weight: .semibold)
    static let pmBody = Font.system(size: 16, weight: .regular)
    static let pmCallout = Font.system(size: 15, weight: .medium)
    static let pmCaption = Font.system(size: 13, weight: .medium)
    static let pmMono = Font.system(size: 13, weight: .medium, design: .monospaced)
}

extension Text {
    /// Section label: small, uppercased, tertiary — the standard header above grouped rows.
    func pmSectionLabel() -> some View {
        self.font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(PM.color.textSecondary)
    }
}
