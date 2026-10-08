import AppKit
import SwiftUI

/// The app's visual identity: one gradient, a few accents, rounded type.
enum Brand {
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)    // #4F46E5
    static let violet = Color(red: 0.49, green: 0.23, blue: 0.93)    // #7C3AED
    static let sky = Color(red: 0.05, green: 0.65, blue: 0.91)       // #0EA5E9
    static let accent = Color(red: 0.25, green: 0.40, blue: 0.96)    // #3F66F5
    static let live = Color(red: 0.13, green: 0.77, blue: 0.37)      // #22C55E
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.04)   // #F59E0B
    static let danger = Color(red: 0.94, green: 0.27, blue: 0.27)    // #EF4444
    static let night = Color(red: 0.07, green: 0.06, blue: 0.20)     // hero backgrounds

    static var gradient: LinearGradient {
        LinearGradient(colors: [indigo, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var dangerGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.98, green: 0.40, blue: 0.40), Color(red: 0.86, green: 0.15, blue: 0.27)],
                       startPoint: .top, endPoint: .bottom)
    }

    static var liveGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.25, green: 0.86, blue: 0.62), live], startPoint: .top, endPoint: .bottom)
    }

    /// Deep night-sky gradient for hero areas.
    static var heroGradient: LinearGradient {
        LinearGradient(colors: [night, Color(red: 0.20, green: 0.13, blue: 0.55), Color(red: 0.03, green: 0.38, blue: 0.62)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func title(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // AppKit colours (MapKit overlays, layers, the icon renderer).
    static var nsIndigo: NSColor { NSColor(srgbRed: 0.31, green: 0.27, blue: 0.90, alpha: 1) }
    static var nsSky: NSColor { NSColor(srgbRed: 0.05, green: 0.65, blue: 0.91, alpha: 1) }
    static var nsLive: NSColor { NSColor(srgbRed: 0.13, green: 0.77, blue: 0.37, alpha: 1) }
    static var nsViolet: NSColor { NSColor(srgbRed: 0.49, green: 0.23, blue: 0.93, alpha: 1) }
}

/// Two-colour fills for icon tiles, System Settings style.
enum TileColors {
    static let brand: [Color] = [Brand.indigo, Brand.sky]
    static let live: [Color] = [Color(red: 0.25, green: 0.86, blue: 0.62), Brand.live]
    static let yellow: [Color] = [Color(red: 1.0, green: 0.80, blue: 0.20), Color(red: 0.96, green: 0.58, blue: 0.05)]
    static let orange: [Color] = [Color(red: 1.0, green: 0.62, blue: 0.25), Color(red: 0.93, green: 0.40, blue: 0.10)]
    static let red: [Color] = [Color(red: 0.99, green: 0.42, blue: 0.42), Color(red: 0.86, green: 0.15, blue: 0.27)]
    static let green: [Color] = [Color(red: 0.35, green: 0.85, blue: 0.45), Color(red: 0.13, green: 0.62, blue: 0.30)]
    static let purple: [Color] = [Color(red: 0.66, green: 0.45, blue: 1.0), Brand.violet]
    static let teal: [Color] = [Color(red: 0.25, green: 0.84, blue: 0.86), Color(red: 0.05, green: 0.55, blue: 0.70)]
    static let gray: [Color] = [Color(red: 0.62, green: 0.64, blue: 0.70), Color(red: 0.42, green: 0.44, blue: 0.50)]
}

// MARK: - Buttons

/// Gradient pill buttons with hover glow and press feedback.
struct BrandButtonStyle: ButtonStyle {
    enum Kind { case primary, danger, live, secondary }
    var kind: Kind = .primary
    var large = true

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, kind: kind, large: large)
    }
}

private struct BrandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: BrandButtonStyle.Kind
    let large: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let corner: CGFloat = large ? 11 : 8
        configuration.label
            .font(Brand.title(large ? 14 : 12, weight: .semibold))
            .foregroundStyle(kind == .secondary ? Color.primary : Color.white)
            .padding(.horizontal, large ? 16 : 11)
            .frame(minHeight: large ? 40 : 28)
            .background { fill }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(kind == .secondary ? Color.primary.opacity(0.12) : Color.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: glow.opacity(isEnabled && kind != .secondary ? (hovering ? 0.5 : 0.28) : 0),
                    radius: hovering ? 12 : 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.06 : (hovering && isEnabled ? 0.04 : 0))
            .saturation(isEnabled ? 1 : 0.15)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: hovering)
    }

    @ViewBuilder private var fill: some View {
        switch kind {
        case .primary: Brand.gradient
        case .danger: Brand.dangerGradient
        case .live: Brand.liveGradient
        case .secondary: Rectangle().fill(.regularMaterial)
        }
    }

    private var glow: Color {
        switch kind {
        case .primary: return Brand.indigo
        case .danger: return Brand.danger
        case .live: return Brand.live
        case .secondary: return .clear
        }
    }
}

/// Round, icon-only buttons used on floating panels.
struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        CircleIconButtonBody(configuration: configuration, size: size, prominent: prominent)
    }
}

private struct CircleIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: size, height: size)
            .background {
                if prominent {
                    Circle().fill(Brand.gradient)
                } else {
                    Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Small building blocks

/// A rounded-square icon with a gradient fill.
struct IconTile: View {
    let symbol: String
    var colors: [Color] = TileColors.brand
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: (colors.last ?? .black).opacity(0.3), radius: size * 0.08, y: size * 0.03)
    }
}

/// A dot with a soft, repeating ripple — "this is live".
struct PulsingDot: View {
    var color: Color = Brand.live
    var size: CGFloat = 8
    var active = true
    @State private var ripple = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                if active {
                    Circle()
                        .fill(color.opacity(0.45))
                        .scaleEffect(ripple ? 2.8 : 1)
                        .opacity(ripple ? 0 : 0.9)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ripple = true }
            }
    }
}

/// Selectable capsule chip.
struct ChoiceChip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.11 : 0.06)),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(selected ? Color.white.opacity(0.2) : Color.primary.opacity(0.06), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

/// Small label + big number.
struct StatTile: View {
    let label: String
    let value: String
    var symbol: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(label.uppercased()).kerning(0.5)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            Text(value)
                .font(Brand.title(15, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A slim gradient progress bar you can drag to seek.
struct ScrubBar: View {
    let fraction: Double
    var interactive: Bool
    var onSeek: (Double) -> Void = { _ in }
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = min(max(dragging ?? fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(Brand.gradient)
                    .frame(width: max(6, width * CGFloat(shown)))
                if interactive && (hovering || dragging != nil) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: min(max(width * CGFloat(shown) - 7, 0), width - 14))
                }
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard interactive else { return }
                        dragging = Double(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        guard interactive else { return }
                        let f = Double(min(max(value.location.x / width, 0), 1))
                        dragging = nil
                        onSeek(f)
                    }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case success, info, warning, error }
    let id = UUID()
    let symbol: String
    let title: String
    var subtitle: String?
    var style: Style = .success

    var colors: [Color] {
        switch style {
        case .success: return TileColors.live
        case .info: return TileColors.brand
        case .warning: return TileColors.orange
        case .error: return TileColors.red
        }
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: toast.symbol, colors: toast.colors, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.system(size: 13, weight: .semibold))
                if let subtitle = toast.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 22)
    }
}
