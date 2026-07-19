import SwiftUI

// MARK: - Card

/// A rounded, elevated surface — the standard container for grouped content.
struct PMCard<Content: View>: View {
    var padding: CGFloat = PM.space.lg
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PM.color.surface, in: RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous)
                .strokeBorder(PM.color.hairline, lineWidth: 1))
    }
}

// MARK: - Buttons

/// Filled brand button — primary actions (Connect, Pair, Run).
struct PMPrimaryButtonStyle: ButtonStyle {
    var tint: Color = PM.color.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pmHeadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, PM.space.md)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous))
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Tinted-fill secondary button.
struct PMSecondaryButtonStyle: ButtonStyle {
    var tint: Color = PM.color.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pmCallout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, PM.space.md)
            .background(tint.opacity(configuration.isPressed ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Status dot

/// A small filled dot in a status tint, optionally pulsing.
struct PMStatusDot: View {
    let tint: Color
    var pulsing = false
    var size: CGFloat = 9
    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .overlay(pulsing ? Circle().stroke(tint.opacity(0.5), lineWidth: 4).scaleEffect(1.6).opacity(0.001) : nil)
            .symbolEffect(.pulse, isActive: pulsing)
    }
}

// MARK: - Settings rows

/// Grouped section: an uppercased label above a card of rows.
struct PMSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: PM.space.sm) {
            Text(title).pmSectionLabel().padding(.horizontal, PM.space.xs)
            VStack(spacing: 0) { content }
                .background(PM.color.surface, in: RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PM.radius.md, style: .continuous)
                    .strokeBorder(PM.color.hairline, lineWidth: 1))
            if let footer {
                Text(footer).font(.pmCaption).foregroundStyle(PM.color.textTertiary).padding(.horizontal, PM.space.xs)
            }
        }
    }
}

/// A single row inside a `PMSection`: icon + title (+ subtitle) + trailing accessory.
struct PMRow<Accessory: View>: View {
    let icon: String
    var iconTint: Color = PM.color.accent
    let title: String
    var subtitle: String? = nil
    var showsDivider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PM.space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 26, height: 26)
                    .background(iconTint.opacity(0.15), in: RoundedRectangle(cornerRadius: PM.radius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.pmBody).foregroundStyle(PM.color.textPrimary)
                    if let subtitle { Text(subtitle).font(.pmCaption).foregroundStyle(PM.color.textTertiary).lineLimit(1) }
                }
                Spacer(minLength: PM.space.sm)
                accessory
            }
            .padding(.horizontal, PM.space.lg)
            .padding(.vertical, PM.space.md)
            if showsDivider { Divider().overlay(PM.color.hairline).padding(.leading, 52) }
        }
    }
}

extension PMRow where Accessory == EmptyView {
    init(icon: String, iconTint: Color = PM.color.accent, title: String, subtitle: String? = nil, showsDivider: Bool = true) {
        self.init(icon: icon, iconTint: iconTint, title: title, subtitle: subtitle, showsDivider: showsDivider) { EmptyView() }
    }
}
