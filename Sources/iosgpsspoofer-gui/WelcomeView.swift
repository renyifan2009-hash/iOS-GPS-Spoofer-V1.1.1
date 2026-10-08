import SpooferCore
import SwiftUI

/// First-launch welcome: an animated hero, what the app does, and a live
/// setup checklist.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHero(shown: shown)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    feature(symbol: "mappin.and.ellipse", colors: TileColors.red, title: "Teleport",
                            text: "Jump anywhere on Earth in an instant.")
                        .stagger(shown, order: 4)
                    feature(symbol: "point.topleft.down.to.point.bottomright.curvepath", colors: TileColors.brand,
                            title: "Routes", text: "Walk or drive real roads, loop or pause.")
                        .stagger(shown, order: 5)
                    feature(symbol: "gamecontroller.fill", colors: TileColors.purple, title: "Joystick",
                            text: "Steer live with WASD or the pad.")
                        .stagger(shown, order: 6)
                    feature(symbol: "iphone.radiowaves.left.and.right", colors: TileColors.teal, title: "iPhone Remote",
                            text: "Control it all from your phone.")
                        .stagger(shown, order: 7)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionHeader("Setup checklist", systemImage: "checklist")
                        Spacer()
                        if model.setupIsComplete {
                            Label("All set", systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.live)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    ForEach(model.setupChecks) { SetupCheckRow(check: $0) }
                }
                .padding(16)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                .animation(.spring(duration: 0.45, bounce: 0.25), value: model.setupIsComplete)
                .stagger(shown, order: 8)
            }
            .padding(24)

            Divider()
            HStack(spacing: 10) {
                Button("Connection help") { showHelp = true }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                    .popover(isPresented: $showHelp, arrowEdge: .top) {
                        ConnectionHelp().padding(18).frame(width: 380)
                    }
                if model.pmd == nil {
                    Button("Choose pymobiledevice3…") { model.choosePymobiledevice3() }
                        .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                }
                Spacer()
                Button {
                    model.finishWelcome()
                } label: {
                    Label("Get Started", systemImage: "arrow.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .padding(.horizontal, 6)
                }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 720)
        .task {
            if model.developerModeEnabled == nil { model.checkDeveloperMode() }
        }
        .onAppear { shown = true }
    }

    private func feature(symbol: String, colors: [Color], title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconTile(symbol: symbol, colors: colors, size: 32)
            Text(title).font(Brand.title(14, weight: .semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

// MARK: - Hero

/// Night sky, a slowly turning globe, a route drawing itself in and the app
/// icon dropping onto its destination with a squash, a bounce and ripples.
private struct WelcomeHero: View {
    let shown: Bool
    @State private var drop = 0
    @State private var routeDrawn: CGFloat = 0
    @State private var ripples = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct IconMotion {
        var offset: Double = 0
        var squash: Double = 1
        var opacity: Double = 1
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(paused: reduceMotion)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                TurningGlobe(phase: context.date.timeIntervalSinceReferenceDate * 0.22)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .frame(width: 560, height: 560)
            .offset(y: 150)

            HeroRoute()
                .trim(from: 0, to: routeDrawn)
                .stroke(LinearGradient(colors: [Brand.live, Brand.indigo, Brand.sky], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.1, 11]))
                .shadow(color: Brand.sky.opacity(0.6), radius: 6)
                .frame(width: 720, height: 300)

            VStack(spacing: 12) {
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        Ellipse()
                            .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                            .frame(width: 70, height: 18)
                            .scaleEffect(ripples ? 2.8 : 0.6)
                            .opacity(ripples ? 0 : 0.8)
                            .animation(.easeOut(duration: 2.1).repeatForever(autoreverses: false).delay(Double(index) * 0.7),
                                       value: ripples)
                    }
                    .offset(y: 52)
                    Image(nsImage: AppIconImage.shared)
                        .resizable()
                        .frame(width: 108, height: 108)
                        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                        .keyframeAnimator(initialValue: IconMotion(), trigger: drop) { content, motion in
                            content
                                .scaleEffect(x: 2 - motion.squash, y: motion.squash, anchor: .bottom)
                                .offset(y: motion.offset)
                                .opacity(motion.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.offset) {
                                MoveKeyframe(-200)
                                CubicKeyframe(-200, duration: 0.12)
                                CubicKeyframe(0, duration: 0.42)
                                SpringKeyframe(-22, duration: 0.22, spring: .bouncy)
                                SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                            }
                            KeyframeTrack(\.squash) {
                                LinearKeyframe(1, duration: 0.54)
                                CubicKeyframe(0.8, duration: 0.07)
                                SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                            }
                            KeyframeTrack(\.opacity) {
                                MoveKeyframe(0)
                                LinearKeyframe(0, duration: 0.1)
                                LinearKeyframe(1, duration: 0.2)
                            }
                        }
                }
                Text("Welcome to iOS GPS Spoofer")
                    .font(Brand.title(30))
                    .foregroundStyle(.white)
                    .stagger(shown, order: 1)
                Text("Put your iPhone anywhere in the world, for testing location-based apps, games and travel plans.")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: 460)
                    .stagger(shown, order: 2)
            }
            .padding(.vertical, 30)
        }
        .frame(height: 310)
        .clipped()
        .onAppear {
            guard !reduceMotion else {
                routeDrawn = 1
                return
            }
            drop += 1
            withAnimation(.easeInOut(duration: 1.3).delay(0.6)) { routeDrawn = 1 }
            Task {
                try? await Task.sleep(for: .seconds(0.75))
                ripples = true
            }
        }
    }
}

/// Drifting night-sky colour: a mesh gradient on macOS 15, glows before.
private struct AuroraBackdrop: View {
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            if #available(macOS 15.0, *) {
                MeshGradient(width: 3, height: 3, points: Self.points(t), colors: Self.colors)
            } else {
                ZStack {
                    Brand.heroGradient
                    Circle().fill(Brand.violet.opacity(0.45)).frame(width: 380).blur(radius: 80)
                        .offset(x: -220 + 40 * cos(t / 5), y: -90 + 20 * sin(t / 4))
                    Circle().fill(Brand.sky.opacity(0.35)).frame(width: 360).blur(radius: 80)
                        .offset(x: 240 + 30 * sin(t / 6), y: 90 + 20 * cos(t / 5))
                }
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

/// Latitude/longitude lines whose meridians turn with `phase`.
private struct TurningGlobe: Shape {
    var phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        for index in 0..<7 {
            let angle = phase + Double(index) * Double.pi / 7
            let half = r * CGFloat(abs(cos(angle)))
            path.addEllipse(in: CGRect(x: c.x - half, y: c.y - r, width: 2 * half, height: 2 * r))
        }
        for k: CGFloat in [-0.66, -0.33, 0, 0.33, 0.66] {
            let y = c.y + r * k
            let half = r * (1 - k * k).squareRoot()
            path.move(to: CGPoint(x: c.x - half, y: y))
            path.addLine(to: CGPoint(x: c.x + half, y: y))
        }
        return path
    }
}

/// From the lower left, curving in to where the icon lands.
private struct HeroRoute: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.08, y: rect.height * 0.92))
        path.addCurve(to: CGPoint(x: rect.midX - 70, y: rect.midY - 10),
                      control1: CGPoint(x: rect.width * 0.2, y: rect.height * 0.4),
                      control2: CGPoint(x: rect.width * 0.3, y: rect.height * 0.75))
        return path
    }
}

/// Latitude/longitude lines of a globe, for decorative backgrounds.
struct GlobeLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        for f: CGFloat in [0.25, 0.55, 0.82] {
            path.addEllipse(in: CGRect(x: c.x - r * f, y: c.y - r, width: 2 * r * f, height: 2 * r))
        }
        for k: CGFloat in [-0.66, -0.33, 0, 0.33, 0.66] {
            let y = c.y + r * k
            let half = r * (1 - k * k).squareRoot()
            path.move(to: CGPoint(x: c.x - half, y: y))
            path.addLine(to: CGPoint(x: c.x + half, y: y))
        }
        return path
    }
}

/// Title first, icon after ("Get Started →").
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

/// Staggered entrance: rise, sharpen and fade in, one element after another.
private struct Stagger: ViewModifier {
    let visible: Bool
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .blur(radius: visible || reduceMotion ? 0 : 6)
            .animation(.spring(duration: 0.7, bounce: 0.2).delay(0.15 + Double(order) * 0.07), value: visible)
    }
}

private extension View {
    func stagger(_ visible: Bool, order: Int) -> some View {
        modifier(Stagger(visible: visible, order: order))
    }
}
