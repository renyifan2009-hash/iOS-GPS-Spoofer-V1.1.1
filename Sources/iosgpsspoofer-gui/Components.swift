import AppKit
import SpooferCore
import SwiftUI

// MARK: - Status

struct StatusDisplay: Equatable {
    var title: String
    var detail: String
    var tint: Color
    var symbol: String
    var busy: Bool
    /// The device is following us right now (pulse the indicator).
    var live: Bool
}

extension AppModel {
    var statusDisplay: StatusDisplay {
        switch sessionState {
        case .idle:
            return StatusDisplay(title: "Ready", detail: "Your iPhone is using its real location.",
                                 tint: .secondary, symbol: "location", busy: false, live: false)
        case .connecting(let message):
            return StatusDisplay(title: "Connecting", detail: message, tint: Brand.warning,
                                 symbol: "antenna.radiowaves.left.and.right", busy: true, live: false)
        case .reconnecting(let message):
            return StatusDisplay(title: "Waiting", detail: message, tint: Brand.warning,
                                 symbol: "cable.connector", busy: true, live: false)
        case .stopping:
            return StatusDisplay(title: "Restoring", detail: "Restoring the real location…", tint: Brand.warning,
                                 symbol: "location.slash", busy: true, live: false)
        case .failed(let message):
            return StatusDisplay(title: "Error", detail: message, tint: Brand.danger,
                                 symbol: "exclamationmark.triangle.fill", busy: false, live: false)
        case .active, .replaying:
            switch activity {
            case .routing:
                if let progress = routeProgress, progress.finished {
                    return StatusDisplay(title: "Arrived", detail: "Holding at the destination.", tint: Brand.accent,
                                         symbol: "flag.checkered", busy: false, live: true)
                }
                if isPaused {
                    return StatusDisplay(title: "Paused", detail: "Route paused.", tint: Brand.warning,
                                         symbol: "pause.fill", busy: false, live: true)
                }
                return StatusDisplay(title: "Moving", detail: "Following the route.", tint: Brand.live,
                                     symbol: "point.topleft.down.to.point.bottomright.curvepath", busy: false, live: true)
            case .joystick:
                return StatusDisplay(title: "Joystick", detail: "Steer with the pad, arrow keys or WASD.", tint: Brand.live,
                                     symbol: "gamecontroller.fill", busy: false, live: true)
            case .holding, .none:
                return StatusDisplay(title: "Live", detail: "Holding the simulated location.", tint: Brand.live,
                                     symbol: "location.fill", busy: false, live: true)
            }
        }
    }
}

struct StatusPill: View {
    let status: StatusDisplay

    var body: some View {
        HStack(spacing: 6) {
            if status.busy {
                ProgressView().controlSize(.mini)
            } else {
                PulsingDot(color: status.tint, size: 7, active: status.live)
            }
            Text(status.title.uppercased())
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .kerning(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(status.tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(status.tint.opacity(0.25), lineWidth: 0.5))
        .foregroundStyle(status.tint == .secondary ? Color.secondary : status.tint)
        .fixedSize()
        .animation(.easeOut(duration: 0.2), value: status)
    }
}

// MARK: - Layout helpers

struct SectionHeader: View {
    let title: String
    var systemImage: String?
    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Brand.gradient)
            }
            Text(title.uppercased()).kerning(0.7)
        }
        .font(.system(size: 10.5, weight: .bold, design: .rounded))
        .foregroundStyle(.secondary)
    }
}

/// A rounded, softly raised group.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

/// Floating panels over the map. On macOS 26 (built with the macOS 26 SDK)
/// they're real Liquid Glass; before that, a frosted material with a lit edge.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 14

    @ViewBuilder
    func body(content: Content) -> some View {
        // Gate on the SDK, not the compiler: a swift.org toolchain can pair
        // Swift 6.2+ with an older Command Line Tools SDK that has no Liquid
        // Glass. SwiftUI 7 is the version in the macOS 26 SDK.
        #if canImport(SwiftUI, _version: 7.0)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            materialPanel(content)
        }
        #else
        materialPanel(content)
        #endif
    }

    private func materialPanel(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 14) -> some View { modifier(GlassPanel(cornerRadius: cornerRadius)) }
}

// MARK: - Speed input

/// Speed entry in the user's units.
struct SpeedField: View {
    @Binding var metresPerSecond: Double
    let units: UnitSystem

    var body: some View {
        HStack(spacing: 6) {
            TextField("Speed", value: displayValue, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
            Text(units.speedUnit).foregroundStyle(.secondary)
        }
    }

    private var displayValue: Binding<Double> {
        Binding(
            get: { (units.displaySpeed(fromMetresPerSecond: metresPerSecond) * 10).rounded() / 10 },
            set: { metresPerSecond = max(0.05, units.metresPerSecond(fromDisplaySpeed: $0)) }
        )
    }
}

/// Labelled preset chips: Walk, Run, Cycle, Drive, Highway.
struct SpeedPresetPicker: View {
    @Binding var metresPerSecond: Double
    let units: UnitSystem

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(SpeedPreset.all) { preset in
                ChoiceChip(title: preset.name, symbol: preset.symbolName,
                           selected: abs(preset.metresPerSecond - metresPerSecond) < 0.05) {
                    metresPerSecond = preset.metresPerSecond
                }
                .help(Format.speed(preset.metresPerSecond, units: units))
            }
        }
    }
}

/// Icon-only speed chips (for the compact joystick panel).
struct SpeedChips: View {
    @Binding var metresPerSecond: Double

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SpeedPreset.all) { preset in
                let selected = abs(preset.metresPerSecond - metresPerSecond) < 0.05
                Button {
                    metresPerSecond = preset.metresPerSecond
                } label: {
                    Image(systemName: preset.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 24)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
    }
}

// MARK: - Duration input

struct DurationField: View {
    @Binding var seconds: TimeInterval

    var body: some View {
        HStack(spacing: 3) {
            unit("h", component: 3600, limit: 99)
            Text(":").foregroundStyle(.secondary)
            unit("m", component: 60, limit: 59)
            Text(":").foregroundStyle(.secondary)
            unit("s", component: 1, limit: 59)
        }
    }

    private func unit(_ label: String, component: Int, limit: Int) -> some View {
        let total = Int(seconds.rounded())
        let binding = Binding<Int>(
            get: {
                switch component {
                case 3600: return total / 3600
                case 60: return (total % 3600) / 60
                default: return total % 60
                }
            },
            set: { newValue in
                let v = min(max(newValue, 0), limit)
                let h = component == 3600 ? v : total / 3600
                let m = component == 60 ? v : (total % 3600) / 60
                let s = component == 1 ? v : total % 60
                seconds = TimeInterval(h * 3600 + m * 60 + s)
            }
        )
        return VStack(spacing: 1) {
            TextField("0", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Log

struct LogConsole: View {
    let entries: [LogEntry]
    let showDebug: Bool

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let visible = showDebug ? entries : entries.filter { $0.level != .debug }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(visible) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.time.string(from: entry.date))
                                .foregroundStyle(.tertiary)
                            Image(systemName: Self.symbol(entry.level))
                                .foregroundStyle(Self.color(entry.level))
                                .font(.system(size: 9))
                            Text(entry.text)
                                .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .id(entry.id)
                    }
                    if visible.isEmpty {
                        Text("Nothing yet — activity shows up here.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .onChange(of: visible.last?.id) {
                if let last = visible.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    static func symbol(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "ellipsis"
        case .info: return "circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    static func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return Brand.accent
        case .success: return Brand.live
        case .warning: return Brand.warning
        case .error: return Brand.danger
        }
    }
}

// MARK: - Misc

struct EngineBadge: View {
    let engine: EngineKind?
    let status: AppModel.EngineStatus

    var body: some View {
        let d = describe
        HStack(spacing: 3) {
            Image(systemName: d.symbol)
            Text(d.text)
        }
        .font(.system(size: 9.5, weight: .bold, design: .rounded))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(d.color.opacity(0.14), in: Capsule())
        .foregroundStyle(d.color)
        .help(d.help)
    }

    private var describe: (text: String, symbol: String, color: Color, help: String) {
        if let engine {
            return engine == .live
                ? ("INSTANT", "bolt.fill", Brand.live, "Live engine: one open channel, instant moves.")
                : ("CLASSIC", "tortoise.fill", Brand.warning, "Classic engine: a new tunnel per move; routes replay as GPX.")
        }
        switch status {
        case .checking:
            return ("CHECKING", "hourglass", .secondary, "Checking whether the live engine works with your pymobiledevice3…")
        case .live:
            return ("INSTANT", "bolt.fill", Brand.live, "The live engine is ready: instant moves, smooth routes, joystick.")
        case .classicOnly(let reason):
            return ("CLASSIC", "tortoise.fill", Brand.warning, "Live engine unavailable: \(reason)")
        }
    }
}

/// A row of the setup checklist.
struct SetupCheckRow: View {
    let check: SetupCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                switch check.state {
                case .ok:
                    IconTile(symbol: "checkmark", colors: TileColors.live, size: 22)
                case .pending:
                    ProgressView().controlSize(.small).frame(width: 22, height: 22)
                case .warning:
                    IconTile(symbol: "exclamationmark", colors: TileColors.orange, size: 22)
                case .failed:
                    IconTile(symbol: "xmark", colors: TileColors.red, size: 22)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.system(size: 13, weight: .semibold))
                Text(check.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.25), value: check.state)
    }
}
