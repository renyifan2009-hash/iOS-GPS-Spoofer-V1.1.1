import SpooferCore
import SwiftUI

/// First-launch welcome: what the app does, plus a live setup checklist.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    feature(symbol: "mappin.and.ellipse", colors: TileColors.red, title: "Teleport",
                            text: "Jump anywhere on Earth in an instant.")
                    feature(symbol: "point.topleft.down.to.point.bottomright.curvepath", colors: TileColors.brand,
                            title: "Routes", text: "Walk or drive real roads, loop or pause.")
                    feature(symbol: "gamecontroller.fill", colors: TileColors.purple, title: "Joystick",
                            text: "Steer live with WASD or the pad.")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionHeader("Setup checklist", systemImage: "checklist")
                        Spacer()
                        if model.setupIsComplete {
                            Label("All set", systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.live)
                        }
                    }
                    ForEach(model.setupChecks) { SetupCheckRow(check: $0) }
                }
                .padding(16)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
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
        .frame(width: 660)
        .task {
            if model.developerModeEnabled == nil { model.checkDeveloperMode() }
        }
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.3)) { appeared = true } }
    }

    private var hero: some View {
        ZStack {
            Brand.heroGradient
            GlobeLines()
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                .frame(width: 520, height: 520)
                .offset(y: 120)
            VStack(spacing: 12) {
                Image(nsImage: AppIconImage.shared)
                    .resizable()
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .opacity(appeared ? 1 : 0)
                Text("Welcome to iOS GPS Spoofer")
                    .font(Brand.title(28))
                    .foregroundStyle(.white)
                Text("Put your iPhone anywhere in the world — for testing location-based apps, games and travel plans.")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: 440)
            }
            .padding(.vertical, 30)
        }
        .frame(height: 290)
        .clipped()
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
