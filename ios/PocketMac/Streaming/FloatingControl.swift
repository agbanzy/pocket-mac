import SwiftUI

/// An AssistiveTouch-style draggable control that floats over the full-screen Mac view: a small
/// translucent circle you can drag anywhere (position persisted), which taps to expand into `panel`
/// (surface switcher + keyboard + status) and collapses back to the circle.
struct FloatingControl<Panel: View>: View {
    @Binding var expanded: Bool
    let statusTint: Color
    @ViewBuilder var panel: () -> Panel

    @State private var position: CGPoint?
    private let size: CGFloat = 54
    private let xKey = "com.innoedge.pocketmac.floatX"
    private let yKey = "com.innoedge.pocketmac.floatY"

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let bounds = geo.size
            let pos = position ?? loadOrDefault(bounds, insets)

            ZStack {
                if expanded {
                    panelCard
                        .position(clamp(pos, bounds: bounds, insets: insets, w: 320, h: 160))
                        .transition(.scale(scale: 0.55, anchor: .center).combined(with: .opacity))
                } else {
                    circle
                        .position(pos)
                        .gesture(drag(bounds: bounds, insets: insets))
                        .onTapGesture { withAnimation(.snappy) { expanded = true } }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: bounds.width, height: bounds.height)
            .onAppear { if position == nil { position = loadOrDefault(bounds, insets) } }
        }
    }

    private var circle: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().strokeBorder(statusTint.opacity(0.9), lineWidth: 2.5)
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .contentShape(Circle())
    }

    private var panelCard: some View {
        VStack(spacing: 12) {
            panel()
            Button { withAnimation(.snappy) { expanded = false } } label: {
                Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .frame(maxWidth: 320)
    }

    private func drag(bounds: CGSize, insets: EdgeInsets) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in position = clamp(v.location, bounds: bounds, insets: insets, w: size, h: size) }
            .onEnded { v in
                let p = clamp(v.location, bounds: bounds, insets: insets, w: size, h: size)
                position = p
                UserDefaults.standard.set(Double(p.x), forKey: xKey)
                UserDefaults.standard.set(Double(p.y), forKey: yKey)
            }
    }

    private func clamp(_ p: CGPoint, bounds: CGSize, insets: EdgeInsets, w: CGFloat, h: CGFloat) -> CGPoint {
        let minX = insets.leading + w / 2 + 6, maxX = bounds.width - insets.trailing - w / 2 - 6
        let minY = insets.top + h / 2 + 6, maxY = bounds.height - insets.bottom - h / 2 - 6
        return CGPoint(x: min(max(p.x, minX), max(minX, maxX)),
                       y: min(max(p.y, minY), max(minY, maxY)))
    }

    private func loadOrDefault(_ bounds: CGSize, _ insets: EdgeInsets) -> CGPoint {
        let d = UserDefaults.standard
        if d.object(forKey: xKey) != nil, d.object(forKey: yKey) != nil {
            return clamp(CGPoint(x: d.double(forKey: xKey), y: d.double(forKey: yKey)),
                         bounds: bounds, insets: insets, w: size, h: size)
        }
        return CGPoint(x: bounds.width - insets.trailing - size / 2 - 14,
                       y: insets.top + size / 2 + 14) // default: top-right
    }
}
