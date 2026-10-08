import SwiftUI

/// SpoofRemote's look: Apple's Liquid Glass (iOS 26 and later, when built
/// with Xcode 26) over a night-sky brand gradient. Every helper falls back
/// to system materials, so the app still builds with Xcode 16 and runs on
/// iOS 17.
enum Brand {
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let violet = Color(red: 0.49, green: 0.23, blue: 0.93)
    static let sky = Color(red: 0.05, green: 0.65, blue: 0.91)
    static let live = Color(red: 0.13, green: 0.77, blue: 0.37)
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let danger = Color(red: 0.94, green: 0.27, blue: 0.27)
    static let night = Color(red: 0.05, green: 0.04, blue: 0.16)

    static var gradient: LinearGradient {
        LinearGradient(colors: [indigo, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var routeGradient: LinearGradient {
        LinearGradient(colors: [live, indigo, sky], startPoint: .leading, endPoint: .trailing)
    }

    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }

    /// The one spring everything moves with, so the app feels of a piece.
    static let spring = Animation.spring(duration: 0.5, bounce: 0.28)
    static let snappy = Animation.spring(duration: 0.32, bounce: 0.18)
}

extension View {
    /// A Liquid Glass surface (iOS 26+), or a frosted material before that.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 28, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.materialSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
        }
        #else
        self.materialSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
        #endif
    }

    /// Capsule-shaped glass, for pills and floating controls.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .capsule)
        } else {
            self.materialSurface(Capsule(), tint: tint)
        }
        #else
        self.materialSurface(Capsule(), tint: tint)
        #endif
    }

    /// Circular glass, for icon buttons.
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(), in: .circle)
        } else {
            self.materialSurface(Circle(), tint: tint)
        }
        #else
        self.materialSurface(Circle(), tint: tint)
        #endif
    }

    private func materialSurface<S: InsettableShape>(_ shape: S, tint: Color?) -> some View {
        self
            .background {
                shape.fill(.ultraThinMaterial)
                shape.fill((tint ?? .clear).opacity(0.22))
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    /// The big call-to-action: glass prominent, tinted.
    @ViewBuilder
    func prominentButton(tint: Color = Brand.indigo) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(tint).controlSize(.large)
        } else {
            self.buttonStyle(ProminentFallbackStyle(tint: tint))
        }
        #else
        self.buttonStyle(ProminentFallbackStyle(tint: tint))
        #endif
    }

    /// Secondary actions: plain glass.
    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).controlSize(.large)
        } else {
            self.buttonStyle(GlassFallbackStyle())
        }
        #else
        self.buttonStyle(GlassFallbackStyle())
        #endif
    }
}

/// Groups neighbouring glass shapes so they blend and morph together on
/// iOS 26; just the content before that.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct ProminentFallbackStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.92), tint], startPoint: .top, endPoint: .bottom))
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                    .padding(1.5)
            }
            .shadow(color: tint.opacity(configuration.isPressed ? 0.2 : 0.45), radius: configuration.isPressed ? 6 : 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Brand.snappy, value: configuration.isPressed)
    }
}

struct GlassFallbackStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 15)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Brand.snappy, value: configuration.isPressed)
    }
}

/// A rounded gradient square with a white symbol, like Settings icons.
struct IconTile: View {
    let symbol: String
    var colors: [Color] = [Brand.indigo, Brand.sky]
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.6)
            }
            .frame(width: size, height: size)
            .shadow(color: (colors.last ?? .black).opacity(0.3), radius: size * 0.12, y: size * 0.05)
    }
}

/// A dot with a soft, repeating ripple: "this is live".
struct PulsingDot: View {
    var color: Color = Brand.live
    var size: CGFloat = 9
    @State private var ripple = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(color.opacity(0.5))
                    .scaleEffect(ripple ? 2.8 : 1)
                    .opacity(ripple ? 0 : 0.9)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { ripple = true }
            }
    }
}

/// The animated night-sky background of the intro and pairing screens:
/// a slowly drifting mesh gradient on iOS 18+, layered glows before that.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            if #available(iOS 18.0, *) {
                MeshGradient(width: 3, height: 3, points: Self.points(t), colors: Self.colors)
                    .ignoresSafeArea()
            } else {
                ZStack {
                    Brand.night
                    Circle().fill(Brand.violet.opacity(0.55)).frame(width: 420).blur(radius: 90)
                        .offset(x: -120 + 40 * cos(t / 5), y: -260 + 30 * sin(t / 4))
                    Circle().fill(Brand.sky.opacity(0.45)).frame(width: 380).blur(radius: 90)
                        .offset(x: 140 + 30 * sin(t / 6), y: 220 + 40 * cos(t / 5))
                    Circle().fill(Brand.indigo.opacity(0.5)).frame(width: 340).blur(radius: 80)
                        .offset(x: 60 * cos(t / 7), y: 40 * sin(t / 6))
                }
                .ignoresSafeArea()
            }
        }
    }

    private static let colors: [Color] = [
        Brand.night, Color(red: 0.20, green: 0.13, blue: 0.55), Brand.night,
        Color(red: 0.16, green: 0.10, blue: 0.48), Brand.indigo, Color(red: 0.03, green: 0.30, blue: 0.55),
        Brand.night, Color(red: 0.03, green: 0.38, blue: 0.62), Color(red: 0.08, green: 0.06, blue: 0.25),
    ]

    private static func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        func wobble(_ base: Float, _ speed: Double, _ amount: Float) -> Float {
            base + amount * Float(sin(t * speed))
        }
        return [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
            SIMD2(0, wobble(0.5, 0.31, 0.08)), SIMD2(wobble(0.5, 0.23, 0.12), wobble(0.5, 0.29, 0.1)), SIMD2(1, wobble(0.5, 0.27, 0.08)),
            SIMD2(0, 1), SIMD2(wobble(0.5, 0.19, 0.1), 1), SIMD2(1, 1),
        ]
    }
}

extension AnyTransition {
    /// Fade, blur and settle into place.
    static var rise: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.96)),
            removal: .opacity.combined(with: .scale(scale: 0.98)))
    }
}
