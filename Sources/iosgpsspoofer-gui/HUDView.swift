import SpooferCore
import SwiftUI

/// Floating status card over the map while a session runs.
struct HUDView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var scrub: Double?

    var body: some View {
        let status = model.statusDisplay
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                StatusPill(status: status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryLine(status))
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(secondaryLine(status))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                controls
            }
            if let progress = model.routeProgress {
                progressView(progress)
            }
        }
        .padding(12)
        .frame(maxWidth: 640)
        .glassPanel(cornerRadius: 14)
    }

    private func primaryLine(_ status: StatusDisplay) -> String {
        switch model.sessionState {
        case .active, .replaying:
            if let name = model.devicePlaceName { return name }
            if let p = model.devicePosition { return Format.coordinate(p) }
            return status.detail
        default:
            return status.detail
        }
    }

    private func secondaryLine(_ status: StatusDisplay) -> String {
        var parts: [String] = []
        if let p = model.devicePosition, model.devicePlaceName != nil || !model.isEngaged {
            parts.append(Format.coordinate(p))
        }
        if model.deviceSpeed > 0.05 {
            parts.append(Format.speed(model.deviceSpeed, units: prefs.units))
            if let heading = model.deviceHeading { parts.append("\(Int(heading.rounded()))° \(Geo.compassPoint(heading))") }
        }
        if let device = model.session?.device { parts.append(device.deviceName) }
        if let engine = model.sessionEngine { parts.append(engine.label) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            if model.canPauseRoute, !(model.routeProgress?.finished ?? false) {
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill").frame(width: 16)
                }
                .help(model.isPaused ? "Resume (⇧⌘P)" : "Pause (⇧⌘P)")
            }
            if model.activity == .routing {
                Button {
                    model.restartRoute()
                } label: {
                    Image(systemName: "backward.end.fill").frame(width: 16)
                }
                .help("Back to the start of the route")
            }
            if model.mode == .joystick, model.activity != .joystick, model.canStream {
                Button("Take Control") { model.takeJoystickControl() }
            }
            Button(role: .destructive) {
                model.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.sessionState == .stopping)
            .help("Stop and restore the real location (⌘↩)")
        }
        .controlSize(.regular)
    }

    private func progressView(_ p: RouteProgressInfo) -> some View {
        VStack(spacing: 4) {
            if model.canPauseRoute {
                Slider(
                    value: Binding(get: { scrub ?? p.fraction }, set: { scrub = $0 }),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing, let value = scrub {
                            model.seekRoute(toFraction: value)
                            scrub = nil
                        }
                    }
                )
                .controlSize(.small)
                .help("Drag to jump along the route")
            } else {
                ProgressView(value: p.fraction).controlSize(.small)
            }
            HStack {
                Text("\(Format.distance(p.lapDistance, units: prefs.units)) of \(Format.distance(p.lapLength, units: prefs.units))")
                Spacer()
                if p.loopMode != .once { Text("Lap \(p.lap + 1)") }
                if p.finished {
                    Label("Arrived", systemImage: "flag.checkered")
                } else if let eta = p.eta {
                    Text(p.loopMode == .once ? "ETA \(Format.duration(eta))" : "Lap ends in \(Format.duration(eta))")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Joystick

struct JoystickPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(spacing: 10) {
            JoystickPad(
                vector: Binding(get: { model.padVector }, set: { model.padVector = $0 }),
                display: model.joystickInput,
                active: model.joystickActive
            )
            SpeedChips(metresPerSecond: $prefs.joystickSpeed)
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if model.joystickActive {
                Text("Arrows / WASD · hold ⇧ to sprint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    if model.session == nil { model.startJoystick() } else { model.takeJoystickControl() }
                } label: {
                    Label(model.session == nil ? "Start Joystick" : "Take Control", systemImage: "gamecontroller.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isStarting || (model.session == nil && !model.canStart))
            }
        }
        .padding(12)
        .frame(width: 210)
        .glassPanel(cornerRadius: 16)
    }

    private var readout: String {
        let max = Format.speed(prefs.joystickSpeed * (model.sprinting ? 2.5 : 1), units: prefs.units)
        if model.joystickActive, model.deviceSpeed > 0.05 {
            return "\(Format.speed(model.deviceSpeed, units: prefs.units)) of \(max)"
        }
        return "Top speed \(max)"
    }
}

/// A drag pad. The knob also mirrors keyboard input.
struct JoystickPad: View {
    @Binding var vector: CGVector
    var display: CGVector
    var active: Bool
    @State private var dragOffset: CGSize?

    private let size: CGFloat = 136
    private let knobSize: CGFloat = 46
    private var travel: CGFloat { (size - knobSize) / 2 }

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary.opacity(0.6))
            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            ForEach(0..<4) { i in
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .offset(y: -size / 2 + 12)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Circle()
                .fill(active ? Color.accentColor.gradient : Color.gray.gradient)
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                .offset(knobOffset)
                .animation(dragOffset == nil ? .spring(duration: 0.25) : nil, value: knobOffset)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var d = CGSize(width: value.location.x - size / 2, height: value.location.y - size / 2)
                    let length = hypot(d.width, d.height)
                    if length > travel {
                        d.width *= travel / length
                        d.height *= travel / length
                    }
                    dragOffset = d
                    vector = CGVector(dx: d.width / travel, dy: -d.height / travel)
                }
                .onEnded { _ in
                    dragOffset = nil
                    vector = .zero
                }
        )
        .opacity(active ? 1 : 0.6)
        .help(active ? "Drag to move the device" : "Start the joystick first")
    }

    private var knobOffset: CGSize {
        if let dragOffset { return dragOffset }
        return CGSize(width: display.dx * travel, height: -display.dy * travel)
    }
}
