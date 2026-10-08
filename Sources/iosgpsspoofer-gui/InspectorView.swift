import AppKit
import SpooferCore
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            DeviceHeader()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch model.mode {
                    case .teleport: TeleportSection()
                    case .route: RouteSection()
                    case .joystick: JoystickSection()
                    }
                    ConnectionSection()
                    LogSection()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ActionBar()
        }
        .background(.background)
    }
}

// MARK: - Header

struct DeviceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let device = model.activeDevice
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                IconTile(symbol: device?.symbolName ?? "iphone.slash",
                         colors: device == nil ? TileColors.gray : TileColors.brand, size: 42)
                if model.isEngaged {
                    PulsingDot(color: Brand.live, size: 9)
                        .padding(2)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: 4, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(device?.deviceName ?? "No iPhone connected")
                    .font(Brand.title(15, weight: .semibold))
                    .lineLimit(1)
                Text(deviceLine(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                StatusPill(status: model.statusDisplay)
                EngineBadge(engine: model.sessionEngine, status: model.engineStatus)
            }
        }
        .padding(14)
    }

    private func deviceLine(_ device: Device?) -> String {
        guard let d = device else { return "Plug it in with a USB cable to begin" }
        return "\(d.modelName) · iOS \(d.productVersion) · \(d.isUSB ? "USB" : "Wi-Fi")"
    }
}

// MARK: - Teleport

struct TeleportSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var model = model
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Destination", systemImage: "mappin.and.ellipse")
            Card {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: "mappin", colors: TileColors.red, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.targetLabel ?? (model.target == nil ? "Pick a place" : "Dropped pin"))
                            .font(Brand.title(16, weight: .semibold))
                            .lineLimit(2)
                        if let t = model.target {
                            Text(Coordinate.formatDMS(t))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text("Click the map, search, or type coordinates.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.toggleFavoriteForTarget()
                    } label: {
                        Image(systemName: model.targetIsFavorite ? "star.fill" : "star")
                            .foregroundStyle(model.targetIsFavorite ? AnyShapeStyle(LinearGradient(colors: TileColors.yellow, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.secondary))
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 30))
                    .disabled(model.target == nil)
                    .help(model.targetIsFavorite ? "Remove from favorites" : "Add to favorites (⌘D)")
                }
                HStack(spacing: 10) {
                    coordinateField("Latitude", text: $model.latitudeText)
                    coordinateField("Longitude", text: $model.longitudeText)
                }
                if model.target == nil {
                    Label("Latitude −90…90, longitude −180…180", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Brand.warning)
                }
                HStack(spacing: 8) {
                    Button {
                        model.pasteFromClipboard()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .help("Paste coordinates or a Google / Apple Maps link (⇧⌘V)")
                    Button {
                        if let t = model.target { model.copyCoordinates(t) }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(model.target == nil)
                    Menu {
                        Button("Apple Maps") { if let t = model.target { model.openInMaps(t, google: false) } }
                        Button("Google Maps") { if let t = model.target { model.openInMaps(t, google: true) } }
                    } label: {
                        Label("Open in", systemImage: "arrow.up.forward.app")
                    }
                    .fixedSize()
                    .disabled(model.target == nil)
                }
                .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                .labelStyle(.titleAndIcon)
            }

            if let device = model.devicePosition, let target = model.target, model.session != nil,
               Geo.distance(device, target) > 1 {
                HStack(spacing: 10) {
                    IconTile(symbol: "arrow.triangle.swap", colors: TileColors.purple, size: 24)
                    Text("\(Format.distance(Geo.distance(device, target), units: prefs.units)) from where your iPhone is now")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            SectionHeader("Quick picks", systemImage: "sparkles")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(NamedLocation.presets) { preset in
                    QuickPickButton(preset: preset,
                                    selected: model.target.map { Geo.distance($0, preset.point) < 60 } ?? false) {
                        model.setTarget(preset.point, name: preset.name, focus: true)
                    }
                }
            }

            Card {
                Toggle(isOn: $prefs.instantTeleport) {
                    HStack(spacing: 10) {
                        IconTile(symbol: "bolt.fill", colors: TileColors.yellow, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Move on map click").font(.system(size: 13, weight: .semibold))
                            Text("While spoofing, clicking the map moves your iPhone at once.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    private func coordinateField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
        }
    }
}

struct QuickPickButton: View {
    let preset: NamedLocation
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(preset.emoji).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset.shortName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !city.isEmpty {
                        Text(city).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(hovering ? 0.09 : 0.045),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.clear), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(preset.name)
    }

    private var city: String {
        preset.name.split(separator: ",").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: ", ")
    }
}

// MARK: - Route

struct RouteSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(model.routeName ?? "Route",
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                Spacer()
                Menu {
                    Button("Import GPX / KML…") { model.importRouteWithPanel() }
                    Button("Export as GPX…") { model.exportRouteWithPanel() }.disabled(model.waypoints.count < 2)
                    Divider()
                    Button(model.savedRouteID == nil ? "Save to Library…" : "Update Saved Route…") {
                        model.saveRouteToLibrary()
                    }
                    .disabled(model.waypoints.count < 2)
                    Divider()
                    Button("Reverse Direction") { model.reverseRoute() }.disabled(model.waypoints.count < 2)
                    Button("Clear All Waypoints", role: .destructive) { model.clearWaypoints() }
                        .disabled(model.waypoints.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import, export, save…")
            }

            if model.waypoints.count >= 2 {
                Card {
                    HStack(spacing: 12) {
                        StatTile(label: "Distance", value: Format.distance(model.routeLength, units: prefs.units),
                                 symbol: "ruler")
                        StatTile(label: model.loopMode == .loop ? "Per lap" : "Time",
                                 value: model.routePassDuration.map { Format.duration($0) } ?? "—", symbol: "clock")
                        StatTile(label: "Stops", value: "\(model.waypoints.count)", symbol: "mappin.and.ellipse")
                    }
                }
            }

            Card {
                if model.waypoints.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(symbol: "hand.tap.fill", colors: TileColors.brand, size: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Click the map to build a route").font(.system(size: 13, weight: .semibold))
                            Text("Drop the start, then the destination, then any stops in between — or drop a GPX / KML file on the map.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    WaypointTimeline()
                }
            }

            Card {
                Toggle(isOn: $model.followRoads) {
                    HStack(spacing: 10) {
                        IconTile(symbol: "road.lanes", colors: TileColors.teal, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Follow roads & paths").font(.system(size: 13, weight: .semibold))
                            Text("Snap each leg to real streets with Apple Maps.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                if model.followRoads {
                    HStack(spacing: 6) {
                        ForEach(TravelMode.allCases) { mode in
                            ChoiceChip(title: mode.label, symbol: mode.symbolName, selected: model.travelMode == mode) {
                                model.travelMode = mode
                            }
                        }
                    }
                    if case .partial(let failed) = model.directionsState {
                        Label("\(failed) leg(s) use straight lines — no route found there.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Brand.warning)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("At the end", systemImage: "flag.checkered")
                HStack(spacing: 6) {
                    ForEach(LoopMode.allCases) { mode in
                        ChoiceChip(title: mode.label, symbol: mode.symbolName, selected: model.loopMode == mode) {
                            model.loopMode = mode
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader("Pace", systemImage: "speedometer")
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(AppModel.RoutePacing.allCases) { pacing in
                            ChoiceChip(title: pacing.label, selected: model.pacing == pacing) { model.pacing = pacing }
                        }
                    }
                }
                switch model.pacing {
                case .speed:
                    SpeedPresetPicker(metresPerSecond: $model.routeSpeed, units: prefs.units)
                    HStack {
                        Text("Custom").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        SpeedField(metresPerSecond: $model.routeSpeed, units: prefs.units)
                    }
                case .time:
                    HStack {
                        DurationField(seconds: $model.routeDuration)
                        Spacer()
                        Text(model.loopMode == .loop ? "per lap" : "start → end")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.activity == .routing, model.canStream {
                    Label("Speed changes apply instantly.", systemImage: "bolt.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Start → stops → destination, drawn as a connected timeline.
struct WaypointTimeline: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: UUID?

    var body: some View {
        let count = model.waypoints.count
        if count > 8 {
            ScrollView {
                rows(count)
            }
            .frame(height: 330)
        } else {
            rows(count)
        }
    }

    private func rows(_ count: Int) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                HStack(spacing: 10) {
                    rail(index: index, count: count)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label(index, count))
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(Format.coordinate(waypoint.point, precision: 5))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if hovered == waypoint.id {
                        HStack(spacing: 2) {
                            Button { model.moveWaypoint(id: waypoint.id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { model.moveWaypoint(id: waypoint.id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == count - 1)
                            Button { model.insertMidpoint(after: waypoint.id) } label: { Image(systemName: "plus") }
                                .help("Insert a stop after this one")
                            Button { model.focus(on: waypoint.point) } label: { Image(systemName: "scope") }
                                .help("Show on map")
                            Button { model.removeWaypoint(id: waypoint.id) } label: { Image(systemName: "trash") }
                                .help("Remove")
                        }
                        .buttonStyle(CircleIconButtonStyle(size: 24))
                        .transition(.opacity)
                    }
                }
                .frame(height: 42)
                .padding(.horizontal, 6)
                .background(hovered == waypoint.id ? Color.primary.opacity(0.05) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .onHover { inside in
                    withAnimation(.easeOut(duration: 0.12)) {
                        hovered = inside ? waypoint.id : (hovered == waypoint.id ? nil : hovered)
                    }
                }
                .onTapGesture(count: 2) { model.focus(on: waypoint.point) }
            }
        }
    }

    private func rail(index: Int, count: Int) -> some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(index == 0 ? Color.clear : Color.primary.opacity(0.15)).frame(width: 2)
                Rectangle().fill(index == count - 1 ? Color.clear : Color.primary.opacity(0.15)).frame(width: 2)
            }
            Circle()
                .fill(LinearGradient(colors: colors(index, count), startPoint: .top, endPoint: .bottom))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        }
        .frame(width: 18)
    }

    private func label(_ index: Int, _ count: Int) -> String {
        if index == 0 { return "Start" }
        if index == count - 1 { return "Destination" }
        return "Stop \(index)"
    }

    private func colors(_ index: Int, _ count: Int) -> [Color] {
        if index == 0 { return TileColors.green }
        if index == count - 1 { return TileColors.red }
        return TileColors.brand
    }
}

// MARK: - Joystick

struct JoystickSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Controls", systemImage: "gamecontroller")
            Card {
                HStack(alignment: .center, spacing: 22) {
                    keyCluster(up: (13, "W"), left: (0, "A"), down: (1, "S"), right: (2, "D"))
                    keyCluster(up: (126, "↑"), left: (123, "←"), down: (125, "↓"), right: (124, "→"))
                }
                .frame(maxWidth: .infinity)
                Text("Hold **⇧** to go 2.5× faster. Or drag the pad on the map. Steering follows the screen, so it works with a rotated map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Top speed", systemImage: "speedometer")
                SpeedPresetPicker(metresPerSecond: $prefs.joystickSpeed, units: prefs.units)
                HStack {
                    Text("Custom").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    SpeedField(metresPerSecond: $prefs.joystickSpeed, units: prefs.units)
                }
            }

            Card {
                HStack(spacing: 12) {
                    IconTile(symbol: "mappin", colors: TileColors.red, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start point").font(.system(size: 13, weight: .semibold))
                        if let start = model.devicePosition ?? model.target {
                            Text(Format.coordinate(start)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(model.devicePosition == nil ? "The teleport target — click the map to change it."
                                 : "Wherever your iPhone is now.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Text("Click the map to choose where to start.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !(model.session?.canStream ?? true) || isClassicOnly {
                Label("The joystick needs the live engine. See Settings ▸ Engine.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Brand.warning)
            }
        }
    }

    private var isClassicOnly: Bool {
        if prefs.enginePreference == .classic { return !(model.activeDevice?.isLegacy ?? false) }
        if case .classicOnly = model.engineStatus { return !(model.activeDevice?.isLegacy ?? false) }
        return false
    }

    private typealias Key = (code: UInt16, label: String)

    private func keyCluster(up: Key, left: Key, down: Key, right: Key) -> some View {
        VStack(spacing: 4) {
            keycap(up)
            HStack(spacing: 4) {
                keycap(left)
                keycap(down)
                keycap(right)
            }
        }
    }

    private func keycap(_ key: Key) -> some View {
        let pressed = model.pressedKeys.contains(key.code)
        return Text(key.label)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(pressed ? Color.white : Color.primary)
            .frame(width: 30, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(pressed ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
            }
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(color: .black.opacity(pressed ? 0 : 0.12), radius: 0, y: pressed ? 0 : 2)
            .offset(y: pressed ? 1 : 0)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

// MARK: - Connection

struct ConnectionSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var expanded = false

    var body: some View {
        @Bindable var prefs = prefs
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Tunnel", selection: $prefs.transport) {
                    ForEach(Transport.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(model.hasSession)
                Text(prefs.transport.detail).font(.caption).foregroundStyle(.secondary)
                Picker("Engine", selection: $prefs.enginePreference) {
                    ForEach(EnginePreference.allCases) { Text($0.label).tag($0) }
                }
                .disabled(model.hasSession)
                engineStatusLine
                if model.activeDevice?.isLegacy == true {
                    Label("iOS 16 or older: uses the lockdown location service; no tunnel needed.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SettingsLink {
                    Text("More settings…")
                }
                .controlSize(.small)
            }
            .padding(.top, 8)
        } label: {
            SectionHeader("Connection", systemImage: "cable.connector")
        }
    }

    @ViewBuilder
    private var engineStatusLine: some View {
        switch model.engineStatus {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking the live engine…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .live(let version):
            Label("Instant live engine ready (pymobiledevice3 \(version))", systemImage: "bolt.fill")
                .font(.caption).foregroundStyle(Brand.live)
        case .classicOnly(let reason):
            Label("Classic engine only: \(reason)", systemImage: "tortoise.fill")
                .font(.caption).foregroundStyle(Brand.warning)
                .lineLimit(3)
        }
    }
}

// MARK: - Log

struct LogSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var expanded = false

    var body: some View {
        @Bindable var prefs = prefs
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                LogConsole(entries: model.log, showDebug: prefs.showDebugLog)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                HStack {
                    Toggle("Details", isOn: $prefs.showDebugLog)
                        .toggleStyle(.checkbox)
                        .help("Show pymobiledevice3's own output")
                    Spacer()
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                        .help("Copy versions, setup and this log, to send to the developer")
                    Button("Clear") { model.clearLog() }
                }
                .controlSize(.small)
            }
            .padding(.top, 8)
        } label: {
            HStack {
                SectionHeader("Activity", systemImage: "waveform.path.ecg")
                if let last = model.log.last(where: { $0.level != .debug }) {
                    Text(last.text)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Action bar

struct ActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            secondaryActions
            Button {
                model.primaryAction()
            } label: {
                HStack(spacing: 11) {
                    if model.isStarting || model.sessionState == .stopping {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon).font(.system(size: 16, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(Brand.title(15, weight: .bold))
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11, weight: .medium))
                                .opacity(0.85)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("⌘↩")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .opacity(0.7)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandButtonStyle(kind: model.hasSession ? .danger : .primary))
            .disabled((!model.hasSession && !model.canStart) || model.sessionState == .stopping)
            .help("Start / stop (⌘↩)")
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if model.session != nil {
            switch model.mode {
            case .teleport:
                if model.target != nil, model.targetDiffersFromDevice || model.activity != .holding {
                    Button {
                        model.teleportToTarget()
                    } label: {
                        Label("Move Here", systemImage: "arrow.up.forward.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                }
            case .route:
                if model.hasPendingRouteChange {
                    Button {
                        model.applyRouteChanges()
                    } label: {
                        Label("Apply Route Changes", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                } else if model.activity != .routing {
                    Button {
                        model.startRoute()
                    } label: {
                        Label("Start Route From Here", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                    .disabled(model.routeGeometry.count < 2)
                }
            case .joystick:
                if model.activity != .joystick {
                    Button {
                        model.takeJoystickControl()
                    } label: {
                        Label("Take Joystick Control", systemImage: "gamecontroller.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle(kind: .secondary))
                    .disabled(!model.canStream)
                }
            }
        }
    }

    private var title: String {
        if model.isStarting { return "Connecting…" }
        if model.hasSession { return model.sessionState == .stopping ? "Restoring…" : "Stop Spoofing" }
        switch model.mode {
        case .teleport: return "Teleport"
        case .route: return "Start Route"
        case .joystick: return "Start Joystick"
        }
    }

    private var subtitle: String? {
        if model.hasSession {
            return model.sessionState == .stopping ? nil : "Return to your real location"
        }
        switch model.mode {
        case .teleport:
            guard let t = model.target else { return nil }
            return model.targetLabel ?? Format.coordinate(t)
        case .route:
            return model.waypoints.count >= 2 ? model.routeSummary : nil
        case .joystick:
            guard let start = model.devicePosition ?? model.target else { return nil }
            return "From \(model.targetLabel ?? Format.coordinate(start))"
        }
    }

    private var icon: String {
        if model.hasSession { return "stop.fill" }
        switch model.mode {
        case .teleport: return "location.fill"
        case .route: return "play.fill"
        case .joystick: return "gamecontroller.fill"
        }
    }

    private var hint: String? {
        if model.hasSession { return nil }
        if model.pmd == nil { return "pymobiledevice3 is needed — see the setup card." }
        if model.selectedDevice == nil { return "Connect and select an iPhone to start." }
        switch model.mode {
        case .teleport, .joystick:
            return model.target == nil ? "Pick a place on the map or enter coordinates." : nil
        case .route:
            if model.waypoints.count < 2 { return "Click the map to add at least two stops." }
            if model.directionsState == .computing { return "Finding the road route…" }
            return nil
        }
    }
}
