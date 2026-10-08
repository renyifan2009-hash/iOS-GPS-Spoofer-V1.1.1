import SpooferCore
import SwiftUI

/// The floating "Now simulating" card over the map while a session runs.
struct HUDView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        let status = model.statusDisplay
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                badge(status)
                VStack(alignment: .leading, spacing: 3) {
                    // Narrow window (a 13-inch laptop with both side panels
                    // open): drop the label, then the engine badge, rather
                    // than wrapping letters.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            nowSimulating
                            StatusPill(status: status)
                            engineBadge
                        }
                        HStack(spacing: 8) {
                            StatusPill(status: status)
                            engineBadge
                        }
                        StatusPill(status: status)
                    }
                    Text(primaryLine(status))
                        .font(Brand.title(status.live ? 17 : 15, weight: .semibold))
                        .lineLimit(status.live ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    Text(secondaryLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                controls
            }

            if let progress = model.routeProgress {
                progressSection(progress)
            } else if model.activity == .joystick || model.deviceSpeed > 0.05 {
                statsRow
            }
        }
        .padding(14)
        .frame(maxWidth: 680)
        .glassPanel(cornerRadius: 18)
    }

    private var nowSimulating: some View {
        Text("NOW SIMULATING")
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    @ViewBuilder
    private var engineBadge: some View {
        if let engine = model.sessionEngine {
            EngineBadge(engine: engine, status: model.engineStatus)
        }
    }

    private func badge(_ status: StatusDisplay) -> some View {
        ZStack {
            Circle()
                .fill(status.live ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(status.tint.opacity(0.18)))
                .frame(width: 46, height: 46)
                .shadow(color: status.live ? Brand.indigo.opacity(0.4) : .clear, radius: 8, y: 2)
            if status.busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(status.live ? Color.white : status.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
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

    private var secondaryLine: String {
        var parts: [String] = []
        if let p = model.devicePosition { parts.append(Format.coordinate(p)) }
        if let device = model.session?.device { parts.append("\(device.deviceName) · \(device.modelName)") }
        return parts.joined(separator: "  ·  ")
    }

    /// The buttons keep their size; the place name truncates instead.
    private var controls: some View {
        HStack(spacing: 8) {
            if model.canRetryConnection {
                Button {
                    model.retryConnection()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
                .help("Reconnect to the iPhone and carry on")
            }
            if model.mode == .joystick, model.activity != .joystick, model.canStream {
                Button("Take Control") { model.takeJoystickControl() }
                    .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
            }
            Button {
                model.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(BrandButtonStyle(kind: .danger, large: false))
            .disabled(model.sessionState == .stopping)
            .help("Stop and restore the real location (⌘↩)")
        }
        .fixedSize()
    }

    /// Pause and back-to-start sit with the progress bar, like a player.
    private var routeTransport: some View {
        HStack(spacing: 6) {
            if model.canPauseRoute, !(model.routeProgress?.finished ?? false) {
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .help(model.isPaused ? "Resume (⇧⌘P)" : "Pause (⇧⌘P)")
            }
            if model.activity == .routing {
                Button {
                    model.restartRoute()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .help("Back to the start of the route")
            }
        }
        .fixedSize()
    }

    /// One clock around both layouts, on a fixed schedule. A TimelineView
    /// inside ViewThatFits is built once per candidate layout, and a schedule
    /// starting at `.now` changes on every evaluation: together they kept
    /// invalidating each other and froze the app.
    private var statsRow: some View {
        TimelineView(.periodic(from: model.sessionStartedAt ?? .distantPast, by: 1)) { context in
            let elapsed = StatTile(label: "Elapsed", value: elapsed(at: context.date), symbol: "clock")
            ViewThatFits(in: .horizontal) {
                EqualColumns(spacing: 14) {
                    speedTile
                    headingTile
                    elapsed
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        speedTile
                        headingTile
                    }
                    GridRow { elapsed }
                }
            }
        }
        .padding(.top, 2)
    }

    private var headingTile: some View {
        StatTile(label: "Heading", value: headingText, symbol: "location.north.line")
    }

    /// The speed, or while a route is stopped, why and for how long.
    @ViewBuilder
    private var speedTile: some View {
        if model.activity == .routing, case let .stopped(reason, remaining) = model.tripStatus {
            let text = TripText(reason: reason, waypointCount: model.waypoints.count)
            StatTile(label: text.label, value: remaining.map(TripText.countdown) ?? "—",
                     symbol: text.symbol, tint: text.tint)
        } else {
            StatTile(label: "Speed", value: Format.speed(model.deviceSpeed, units: prefs.units), symbol: "speedometer")
        }
    }

    private var headingText: String {
        guard model.deviceSpeed > 0.05, let heading = model.deviceHeading else { return "—" }
        return "\(Int(heading.rounded()))° \(Geo.compassPoint(heading))"
    }

    private func elapsed(at date: Date) -> String {
        guard let start = model.sessionStartedAt else { return "—" }
        let seconds = Int(max(0, date.timeIntervalSince(start)))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private func routeTiles(_ p: RouteProgressInfo) -> some View {
        coveredTile(p)
        speedTile
        timeTile(p)
        if p.loopMode != .once { lapTile(p) }
    }

    private func coveredTile(_ p: RouteProgressInfo) -> some View {
        StatTile(label: "Covered",
                 value: "\(Format.distance(p.lapDistance, units: prefs.units)) / \(Format.distance(p.lapLength, units: prefs.units))",
                 symbol: "point.topleft.down.to.point.bottomright.curvepath")
    }

    @ViewBuilder
    private func timeTile(_ p: RouteProgressInfo) -> some View {
        if p.finished {
            StatTile(label: "Status", value: "Arrived", symbol: "flag.checkered")
        } else {
            StatTile(label: p.loopMode == .once ? "ETA" : "Lap ends",
                     value: p.eta.map { Format.duration($0) } ?? "—", symbol: "timer")
        }
    }

    private func lapTile(_ p: RouteProgressInfo) -> some View {
        StatTile(label: "Lap", value: "\(p.lap + 1)", symbol: p.loopMode.symbolName)
    }

    private func progressSection(_ p: RouteProgressInfo) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                routeTransport
                ScrubBar(fraction: p.fraction, interactive: model.canPauseRoute) { value in
                    model.seekRoute(toFraction: value)
                }
                .help(model.canPauseRoute ? "Drag to jump along the route" : "")
            }
            // One row when there's room; two when the window is narrow.
            ViewThatFits(in: .horizontal) {
                EqualColumns(spacing: 14) { routeTiles(p) }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        coveredTile(p)
                        speedTile
                    }
                    GridRow {
                        timeTile(p)
                        if p.loopMode != .once { lapTile(p) }
                    }
                }
            }
        }
    }
}

/// Words, symbols and colours for why a trip has stopped.
struct TripText {
    let reason: TripStop.Reason
    let waypointCount: Int

    var label: String {
        switch reason {
        case .redLight: return "Red light"
        case .stopSign: return "Stop sign"
        case .giveWay: return "Yield"
        case .crossing: return "Crosswalk"
        case .waypoint(let index):
            if index == 0 { return "At the start" }
            if index == waypointCount - 1 { return "At the destination" }
            return "At stop \(index)"
        case .destination: return "Arrived"
        case .turnaround: return "Turning around"
        case .rest: return "Break"
        case .pause: return "Pause"
        }
    }

    var symbol: String {
        switch reason {
        case .redLight: return "circle.fill"
        case .stopSign: return "octagon.fill"
        case .giveWay: return "triangle.fill"
        case .crossing: return "figure.walk"
        case .waypoint: return "mappin.and.ellipse"
        case .destination: return "flag.checkered"
        case .turnaround: return "arrow.uturn.left"
        case .rest: return "cup.and.saucer.fill"
        case .pause: return "pause.circle.fill"
        }
    }

    var tint: Color? {
        switch reason {
        case .redLight, .stopSign: return Color(red: 0.86, green: 0.15, blue: 0.20)
        case .giveWay: return .orange
        case .crossing: return Brand.sky
        default: return nil
        }
    }

    /// "0:34", "12:05".
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Joystick

struct JoystickPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(spacing: 12) {
            HStack {
                Text("JOYSTICK")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.joystickActive { PulsingDot(color: Brand.live, size: 6) }
            }
            JoystickPad(
                vector: Binding(get: { model.padVector }, set: { model.padVector = $0 }),
                display: model.joystickInput,
                active: model.joystickActive
            )
            SpeedChips(metresPerSecond: $prefs.joystickSpeed)
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if model.joystickActive {
                Text("WASD / arrows · hold ⇧ to sprint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    if model.session == nil { model.startJoystick() } else { model.takeJoystickControl() }
                } label: {
                    Label(model.session == nil ? "Start Joystick" : "Take Control", systemImage: "gamecontroller.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
                .disabled(model.isStarting || (model.session == nil && !model.canStart))
            }
        }
        .padding(14)
        .frame(width: 214)
        .glassPanel(cornerRadius: 20)
    }

    private var readout: String {
        let top = Format.speed(prefs.joystickSpeed * (model.sprinting ? 2.5 : 1), units: prefs.units)
        if model.joystickActive, model.deviceSpeed > 0.05 {
            return "\(Format.speed(model.deviceSpeed, units: prefs.units)) of \(top)"
        }
        return "Top speed \(top)"
    }
}

/// A drag pad. The knob also mirrors keyboard input.
struct JoystickPad: View {
    @Binding var vector: CGVector
    var display: CGVector
    var active: Bool
    @State private var dragOffset: CGSize?

    private let size: CGFloat = 148
    private let knobSize: CGFloat = 52
    private var travel: CGFloat { (size - knobSize) / 2 }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.primary.opacity(0.03), Color.primary.opacity(0.10)],
                                     center: .center, startRadius: 4, endRadius: size / 2))
            Circle()
                .strokeBorder(active ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)),
                              lineWidth: active ? 2 : 1)
            Circle()
                .strokeBorder(Color.primary.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .padding(size * 0.22)
            ForEach(0..<4) { i in
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.tertiary)
                    .offset(y: -size / 2 + 13)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            Circle()
                .fill(active ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.gray.gradient))
                .frame(width: knobSize, height: knobSize)
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.5))
                .overlay {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .rotationEffect(knobAngle)
                        .opacity(knobOffset == .zero ? 0.4 : 1)
                }
                .shadow(color: (active ? Brand.indigo : Color.black).opacity(0.35), radius: 6, y: 3)
                .offset(knobOffset)
                .animation(dragOffset == nil ? .spring(duration: 0.3, bounce: 0.35) : nil, value: knobOffset)
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
        .opacity(active ? 1 : 0.65)
        .help(active ? "Drag to move the device" : "Start the joystick first")
    }

    private var knobOffset: CGSize {
        if let dragOffset { return dragOffset }
        return CGSize(width: display.dx * travel, height: -display.dy * travel)
    }

    private var knobAngle: Angle {
        let o = knobOffset
        guard o != .zero else { return .zero }
        return .radians(Double(atan2(o.width, -o.height)))
    }
}
