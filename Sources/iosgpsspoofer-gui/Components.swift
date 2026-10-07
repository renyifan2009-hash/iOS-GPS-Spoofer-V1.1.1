import AppKit
import SpooferCore
import SwiftUI

// MARK: - Status

struct StatusDisplay: Equatable {
    var title: String
    var detail: String
    var tint: Color
    var busy: Bool
}

extension AppModel {
    var statusDisplay: StatusDisplay {
        switch sessionState {
        case .idle:
            return StatusDisplay(title: "Idle", detail: "The device reports its real location.", tint: .secondary, busy: false)
        case .connecting(let message):
            return StatusDisplay(title: "Connecting", detail: message, tint: .orange, busy: true)
        case .reconnecting(let message):
            return StatusDisplay(title: "Waiting", detail: message, tint: .yellow, busy: true)
        case .stopping:
            return StatusDisplay(title: "Restoring", detail: "Restoring the real location…", tint: .orange, busy: true)
        case .failed(let message):
            return StatusDisplay(title: "Error", detail: message, tint: .red, busy: false)
        case .active, .replaying:
            switch activity {
            case .routing:
                if let progress = routeProgress, progress.finished {
                    return StatusDisplay(title: "Arrived", detail: "Holding at the destination.", tint: .blue, busy: false)
                }
                if isPaused {
                    return StatusDisplay(title: "Paused", detail: "Route paused.", tint: .yellow, busy: false)
                }
                return StatusDisplay(title: "Moving", detail: "Following the route.", tint: .green, busy: false)
            case .joystick:
                return StatusDisplay(title: "Joystick", detail: "Steer with the pad, arrow keys or WASD.", tint: .green, busy: false)
            case .holding, .none:
                return StatusDisplay(title: "Spoofing", detail: "Holding the simulated location.", tint: .green, busy: false)
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
                Circle().fill(status.tint).frame(width: 8, height: 8)
                    .shadow(color: status.tint.opacity(0.6), radius: status.tint == .secondary ? 0 : 3)
            }
            Text(status.title).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(status.tint.opacity(0.15), in: Capsule())
        .foregroundStyle(status.tint == .secondary ? Color.secondary : status.tint)
        .fixedSize()
        .animation(.default, value: status)
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
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title.uppercased()).kerning(0.6)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// A rounded, subtly filled group, like System Settings rows.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Floating glass panel used over the map.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 12) -> some View { modifier(GlassPanel(cornerRadius: cornerRadius)) }
}

// MARK: - Speed input

/// Speed entry in the user's units, with quick presets.
struct SpeedField: View {
    @Binding var metresPerSecond: Double
    let units: UnitSystem

    var body: some View {
        HStack(spacing: 6) {
            TextField("Speed", value: displayValue, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
            Text(units.speedUnit).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Menu {
                ForEach(SpeedPreset.all) { preset in
                    Button {
                        metresPerSecond = preset.metresPerSecond
                    } label: {
                        Label("\(preset.name) — \(Format.speed(preset.metresPerSecond, units: units))",
                              systemImage: preset.symbolName)
                    }
                }
            } label: {
                Image(systemName: presetSymbol)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Speed presets")
        }
    }

    private var displayValue: Binding<Double> {
        Binding(
            get: { (units.displaySpeed(fromMetresPerSecond: metresPerSecond) * 10).rounded() / 10 },
            set: { metresPerSecond = max(0.05, units.metresPerSecond(fromDisplaySpeed: $0)) }
        )
    }

    private var presetSymbol: String {
        SpeedPreset.all.min(by: { abs($0.metresPerSecond - metresPerSecond) < abs($1.metresPerSecond - metresPerSecond) })?
            .symbolName ?? "speedometer"
    }
}

/// Quick speed chips (for the joystick).
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
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.plain)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
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
                .frame(width: 44)
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
                LazyVStack(alignment: .leading, spacing: 2) {
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
                        Text("Nothing yet.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
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
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Misc

struct EngineBadge: View {
    let engine: EngineKind?
    let status: AppModel.EngineStatus

    var body: some View {
        let d = describe
        Text(d.text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(d.color.opacity(0.15), in: Capsule())
            .foregroundStyle(d.color)
            .help(d.help)
    }

    private var describe: (text: String, color: Color, help: String) {
        if let engine {
            return engine == .live
                ? ("LIVE", .green, "Live engine: one open channel, instant moves.")
                : ("CLASSIC", .orange, "Classic engine: a new tunnel per move; routes replay as GPX.")
        }
        switch status {
        case .checking: return ("CHECKING", .secondary, "Checking whether the live engine works with your pymobiledevice3…")
        case .live: return ("LIVE READY", .green, "The live engine is available.")
        case .classicOnly(let reason): return ("CLASSIC", .orange, "Live engine unavailable: \(reason)")
        }
    }
}
