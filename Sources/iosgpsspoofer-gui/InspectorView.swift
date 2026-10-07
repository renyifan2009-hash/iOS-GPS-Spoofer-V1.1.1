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
                VStack(alignment: .leading, spacing: 18) {
                    switch model.mode {
                    case .teleport: TeleportSection()
                    case .route: RouteSection()
                    case .joystick: JoystickSection()
                    }
                    ConnectionSection()
                    LogSection()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ActionBar()
        }
        .background(.background)
    }
}

// MARK: - Header

struct DeviceHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.activeDevice?.symbolName ?? "iphone.slash")
                .font(.system(size: 26))
                .foregroundStyle(model.activeDevice == nil ? Color.secondary : Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.activeDevice?.deviceName ?? "No device").font(.headline).lineLimit(1)
                    EngineBadge(engine: model.sessionEngine, status: model.engineStatus)
                }
                Text(deviceLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            StatusPill(status: model.statusDisplay)
        }
        .padding(12)
    }

    private var deviceLine: String {
        guard let d = model.activeDevice else { return "Connect an iPhone with a cable to begin" }
        return "\(d.modelName) · iOS \(d.productVersion) · \(d.isUSB ? "USB" : "Wi-Fi")"
    }
}

// MARK: - Teleport

struct TeleportSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(LibraryStore.self) private var library

    var body: some View {
        @Bindable var model = model
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Destination", systemImage: "mappin.and.ellipse")
            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.targetLabel ?? (model.target == nil ? "No location" : "Unnamed place"))
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        if let t = model.target {
                            Text(Coordinate.formatDMS(t)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button {
                        model.toggleFavoriteForTarget()
                    } label: {
                        Image(systemName: model.targetIsFavorite ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(model.targetIsFavorite ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.target == nil)
                    .help(model.targetIsFavorite ? "Remove from favorites" : "Add to favorites (⌘D)")
                }
                HStack(spacing: 10) {
                    coordinateField("Latitude", text: $model.latitudeText)
                    coordinateField("Longitude", text: $model.longitudeText)
                }
                if model.target == nil {
                    Label("Latitude −90…90, longitude −180…180", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
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
                        Label("Open", systemImage: "arrow.up.forward.app")
                    }
                    .fixedSize()
                    .disabled(model.target == nil)
                }
                .controlSize(.small)
                .labelStyle(.titleAndIcon)
            }

            if let device = model.devicePosition, let target = model.target, model.session != nil,
               Geo.distance(device, target) > 1 {
                Label("\(Format.distance(Geo.distance(device, target), units: prefs.units)) from the device’s current spot",
                      systemImage: "arrow.triangle.swap")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SectionHeader("Quick picks", systemImage: "sparkles")
            Menu {
                Section("Landmarks") {
                    ForEach(NamedLocation.presets) { preset in
                        Button(preset.name) { model.setTarget(preset.point, name: preset.name, focus: true) }
                    }
                }
                if !library.favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(library.favorites.prefix(15)) { place in
                            Button(place.name) { model.setTarget(place.point, name: place.name, focus: true) }
                        }
                    }
                }
            } label: {
                Label("Landmarks & favorites", systemImage: "mappin.circle")
            }
            .fixedSize()

            Toggle(isOn: $prefs.instantTeleport) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Move as soon as I click the map")
                    Text("While spoofing with the live engine — no need to press Move.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private func coordinateField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
        }
    }
}

// MARK: - Route

struct RouteSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(model.routeName.map { "Route — \($0)" } ?? "Route",
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
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Card {
                if model.waypoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Click the map to drop the start, then the destination, then any stops in between.",
                              systemImage: "hand.tap")
                        Label("Or drop a GPX / KML file on the map.", systemImage: "square.and.arrow.down")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                } else {
                    WaypointList()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.followRoads) {
                    Label("Follow roads & paths", systemImage: "road.lanes")
                }
                .toggleStyle(.switch)
                if model.followRoads {
                    Picker("Travel mode", selection: $model.travelMode) {
                        ForEach(TravelMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if case .partial(let failed) = model.directionsState {
                        Label("\(failed) leg(s) use straight lines (no route found).", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("At the end", systemImage: "flag.checkered")
                Picker("At the end", selection: $model.loopMode) {
                    ForEach(LoopMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionHeader("Pace", systemImage: "speedometer")
                    Spacer()
                    Picker("Pace by", selection: $model.pacing) {
                        ForEach(AppModel.RoutePacing.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                switch model.pacing {
                case .speed:
                    SpeedField(metresPerSecond: $model.routeSpeed, units: prefs.units)
                case .time:
                    HStack {
                        DurationField(seconds: $model.routeDuration)
                        Spacer()
                        Text(model.loopMode == .loop ? "per lap" : "start → end")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.waypoints.count >= 2 {
                    Label(model.routeSummary, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.activity == .routing, model.canStream {
                    Text("Speed changes apply immediately.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct WaypointList: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: UUID?

    var body: some View {
        let count = model.waypoints.count
        LazyVStack(spacing: 2) {
            ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                HStack(spacing: 8) {
                    Text(index == 0 ? "A" : (index == count - 1 ? "B" : "\(index + 1)"))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(badgeColor(index, count), in: Circle())
                    Text(Format.coordinate(waypoint.point, precision: 5))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if hovered == waypoint.id {
                        Group {
                            Button { model.moveWaypoint(id: waypoint.id, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { model.moveWaypoint(id: waypoint.id, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == count - 1)
                            Button { model.insertMidpoint(after: waypoint.id) } label: { Image(systemName: "plus.circle") }
                                .help("Insert a point after this one")
                            Button { model.focus(on: waypoint.point) } label: { Image(systemName: "scope") }
                                .help("Show on map")
                            Button(role: .destructive) { model.removeWaypoint(id: waypoint.id) } label: { Image(systemName: "trash") }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(hovered == waypoint.id ? Color.primary.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? waypoint.id : (hovered == waypoint.id ? nil : hovered) }
                .onTapGesture(count: 2) { model.focus(on: waypoint.point) }
            }
        }
        .frame(maxHeight: count > 8 ? 260 : nil)
    }

    private func badgeColor(_ index: Int, _ count: Int) -> Color {
        if index == 0 { return .green }
        if index == count - 1 { return .red }
        return .blue
    }
}

// MARK: - Joystick

struct JoystickSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Joystick", systemImage: "gamecontroller")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    keyRow(["↑", "W"], "Forward (screen-up)")
                    keyRow(["←", "A", "→", "D"], "Turn left / right")
                    keyRow(["↓", "S"], "Back")
                    keyRow(["⇧"], "Hold to go 2.5× faster")
                }
                Text("Or drag the pad on the map. Movement is relative to the screen, so it follows map rotation.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("Top speed", systemImage: "speedometer")
                SpeedField(metresPerSecond: $prefs.joystickSpeed, units: prefs.units)
                SpeedChips(metresPerSecond: $prefs.joystickSpeed)
            }

            VStack(alignment: .leading, spacing: 4) {
                SectionHeader("Start point", systemImage: "mappin")
                if let start = model.devicePosition ?? model.target {
                    Text(Format.coordinate(start)).font(.callout.monospaced())
                    Text(model.devicePosition == nil ? "The teleport target — click the map to change it." : "The device's current position.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Click the map to choose where to start.").font(.callout).foregroundStyle(.secondary)
                }
            }

            if !(model.session?.canStream ?? true) || isClassicOnly {
                Label("The joystick needs the live engine. See Settings ▸ Engine.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var isClassicOnly: Bool {
        if prefs.enginePreference == .classic { return !(model.activeDevice?.isLegacy ?? false) }
        if case .classicOnly = model.engineStatus { return !(model.activeDevice?.isLegacy ?? false) }
        return false
    }

    private func keyRow(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.caption.monospaced().bold())
                    .frame(minWidth: 20, minHeight: 18)
                    .padding(.horizontal, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            }
            Text(text).font(.callout).padding(.leading, 4)
        }
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
            .padding(.top, 6)
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
            Label("Live engine available (pymobiledevice3 \(version))", systemImage: "bolt.fill")
                .font(.caption).foregroundStyle(.green)
        case .classicOnly(let reason):
            Label("Classic engine only: \(reason)", systemImage: "tortoise.fill")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(3)
        }
    }
}

// MARK: - Log

struct LogSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var expanded = true

    var body: some View {
        @Bindable var prefs = prefs
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                LogConsole(entries: model.log, showDebug: prefs.showDebugLog)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                HStack {
                    Toggle("Details", isOn: $prefs.showDebugLog)
                        .toggleStyle(.checkbox)
                        .help("Show pymobiledevice3's own output")
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.logText, forType: .string)
                    }
                    Button("Clear") { model.clearLog() }
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        } label: {
            SectionHeader("Activity", systemImage: "text.alignleft")
        }
    }
}

// MARK: - Action bar

struct ActionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            secondaryActions
            Button {
                model.primaryAction()
            } label: {
                HStack {
                    if model.isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon)
                    }
                    Text(title).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.hasSession ? .red : .accentColor)
            .disabled(!model.hasSession && !model.canStart)
            .help("Start / stop (⌘↩)")
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .background(.bar)
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
                    .controlSize(.large)
                }
            case .route:
                if model.hasPendingRouteChange {
                    Button {
                        model.applyRouteChanges()
                    } label: {
                        Label("Apply Route Changes", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else if model.activity != .routing {
                    Button {
                        model.startRoute()
                    } label: {
                        Label("Start Route From Here", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.routeGeometry.count < 2)
                }
            case .joystick:
                if model.activity != .joystick {
                    Button {
                        model.takeJoystickControl()
                    } label: {
                        Label("Take Joystick Control", systemImage: "gamecontroller.fill").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(!model.canStream)
                }
            }
        }
    }

    private var title: String {
        if model.isStarting { return "Starting…" }
        if model.hasSession { return model.sessionState == .stopping ? "Restoring…" : "Stop & Restore Real Location" }
        switch model.mode {
        case .teleport: return "Teleport"
        case .route: return "Start Route"
        case .joystick: return "Start Joystick"
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
            if model.waypoints.count < 2 { return "Click the map to add at least two waypoints." }
            if model.directionsState == .computing { return "Finding the road route…" }
            return nil
        }
    }
}
