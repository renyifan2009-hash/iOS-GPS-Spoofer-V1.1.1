import AppKit
import SpooferCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Map-related model helpers

extension AppModel {
    static let targetPinID = UUID()

    var mapPins: [MapPin] {
        switch mode {
        case .teleport:
            guard let target else { return [] }
            return [MapPin(id: Self.targetPinID, point: target, role: .target)]
        case .joystick:
            guard session == nil, let target else { return [] }
            return [MapPin(id: Self.targetPinID, point: target, role: .target)]
        case .route:
            let n = waypoints.count
            let compact = n > 60
            return waypoints.enumerated().map { i, w in
                let role: MapPin.Role
                if i == 0 { role = .start }
                else if i == n - 1 { role = .end }
                else { role = compact ? .compact : .waypoint(i + 1) }
                return MapPin(id: w.id, point: w.point, role: role)
            }
        }
    }

    var deviceMarker: DeviceMarker? {
        guard session != nil, let devicePosition else { return nil }
        return DeviceMarker(point: devicePosition, heading: deviceSpeed > 0 ? deviceHeading : nil, live: isEngaged)
    }

    func pinDragged(_ id: UUID, to point: GeoPoint) {
        if id == Self.targetPinID {
            setTarget(point)
            if prefs.instantTeleport, session != nil, canStream, mode == .teleport { teleport(to: point, name: nil) }
        } else {
            moveWaypoint(id: id, to: point)
        }
    }

    func performContextAction(_ action: MapContextAction, at point: GeoPoint) {
        switch action {
        case .teleportHere:
            setTarget(point)
            if mode == .route { mode = .teleport }
            teleport(to: point, name: nil)
        case .setTarget:
            if mode == .route { mode = .teleport }
            setTarget(point)
        case .addWaypoint:
            mode = .route
            addWaypoint(point)
        case .joystickHere:
            setTarget(point)
            mode = .joystick
            if let session, session.canStream {
                teleport(to: point, name: nil)
                activity = .joystick
            } else if session == nil {
                startJoystick()
            }
        case .addFavorite:
            addFavorite(at: point, suggestedName: nil)
        case .copyCoordinates:
            copyCoordinates(point)
        }
    }

    /// A place picked from search.
    func placeChosen(_ point: GeoPoint, name: String) {
        switch mode {
        case .route:
            addWaypoint(point)
            focus(on: point)
        case .teleport:
            setTarget(point, name: name, focus: true)
            if prefs.instantTeleport, session != nil, canStream { teleport(to: point, name: name) }
        case .joystick:
            setTarget(point, name: name, focus: true)
            if activity == .joystick, canStream {
                teleport(to: point, name: name)
                activity = .joystick
            }
        }
    }
}

// MARK: - Main view

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @State private var search = PlaceSearch()
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        mapLayer
            .overlay(alignment: .topLeading) {
                SearchBar(search: search).padding(12)
            }
            .overlay(alignment: .topTrailing) {
                MapControls().padding(12)
            }
            .overlay(alignment: .top) {
                Banners().padding(.top, 64)
            }
            .overlay(alignment: .bottom) {
                if model.hasSession {
                    HUDView()
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if model.mode == .joystick {
                    JoystickPanel()
                        .padding(14)
                        .padding(.bottom, model.hasSession ? 110 : 0)
                        .transition(.opacity)
                }
            }
            .overlay {
                if model.setupError != nil {
                    SetupCard().transition(.opacity)
                } else if dropTargeted {
                    DropHint()
                }
            }
            .animation(.snappy(duration: 0.25), value: model.hasSession)
            .animation(.snappy(duration: 0.25), value: model.mode)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { RouteImporter.supportedExtensions.contains($0.pathExtension.lowercased()) })
                else { return false }
                model.importRoute(from: url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .inspector(isPresented: $model.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(AppModel.Mode.allCases) { mode in
                            Label(mode.label, systemImage: mode.symbolName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.titleAndIcon)
                    .help("Teleport (⌘1) · Route (⌘2) · Joystick (⌘3)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.showInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help("Show or hide the inspector (⌥⌘I)")
                }
            }
            .navigationTitle(model.activeDevice?.deviceName ?? "iOS GPS Spoofer")
            .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let device = model.activeDevice else { return "No device" }
        if model.hasSession { return model.statusDisplay.title }
        return "\(device.modelName) · iOS \(device.productVersion)"
    }

    private var mapLayer: some View {
        MapPicker(
            pins: model.mapPins,
            route: model.displayedRoute,
            travelledFraction: model.travelledFraction,
            isPlaying: model.activity == .routing,
            device: model.deviceMarker,
            style: prefs.mapStyle,
            focus: model.mapFocus,
            follow: prefs.followDevice && model.session != nil,
            contextActions: [.teleportHere, .setTarget, .addWaypoint, .joystickHere, .addFavorite, .copyCoordinates],
            onClick: { model.mapClicked($0) },
            onDragPin: { id, point in model.pinDragged(id, to: point) },
            onContextAction: { action, point in model.performContextAction(action, at: point) },
            onCameraChange: { center, span, heading in
                if abs(model.mapHeading - heading) > 0.01 { model.mapHeading = heading }
                search.setRegion(center: center, spanDegrees: min(max(span * 2, 0.2), 40))
            }
        )
    }
}

// MARK: - Search

struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @Bindable var search: PlaceSearch
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search, or paste coordinates / a maps link", text: $search.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { choose(search.highlighted) }
                    .onKeyPress(.downArrow) {
                        search.moveHighlight(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        search.moveHighlight(-1)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        search.clear()
                        focused = false
                        return .handled
                    }
                if search.isResolving {
                    ProgressView().controlSize(.small)
                } else if !search.query.isEmpty {
                    Button {
                        search.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            if !search.query.isEmpty && !search.suggestions.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(search.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button {
                            choose(index)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: suggestion.symbolName)
                                    .foregroundStyle(index == search.highlighted ? Color.white : Color.accentColor)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title).lineLimit(1)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle).font(.caption).lineLimit(1)
                                            .foregroundStyle(index == search.highlighted ? Color.white.opacity(0.85) : Color.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .foregroundStyle(index == search.highlighted ? Color.white : Color.primary)
                            .background(index == search.highlighted ? Color.accentColor : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in if inside { search.highlighted = index } }
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 380)
        .glassPanel()
        .onChange(of: model.searchFocusRequest) { focused = true }
    }

    private func choose(_ index: Int) {
        guard search.suggestions.indices.contains(index) else { return }
        let suggestion = search.suggestions[index]
        Task {
            guard let place = await search.resolve(suggestion) else {
                model.appendLog("Couldn't locate “\(suggestion.title)”.", level: .warning)
                return
            }
            model.placeChosen(place.point, name: place.name)
            search.clear()
            focused = false
        }
    }
}

// MARK: - Map controls

struct MapControls: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(spacing: 0) {
            Menu {
                Picker("Map Style", selection: $prefs.mapStyle) {
                    ForEach(MapStyle.allCases) { style in
                        Label(style.label, systemImage: style.symbolName).tag(style)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: prefs.mapStyle.symbolName)
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Map style")

            Divider().frame(width: 22)

            Button {
                model.fitMap()
            } label: {
                Image(systemName: "scope").frame(width: 30, height: 28)
            }
            .help("Fit the map to what matters (⌘0)")

            Divider().frame(width: 22)

            Button {
                prefs.followDevice.toggle()
            } label: {
                Image(systemName: prefs.followDevice ? "location.circle.fill" : "location.circle")
                    .foregroundStyle(prefs.followDevice ? Color.accentColor : Color.primary)
                    .frame(width: 30, height: 28)
            }
            .help(prefs.followDevice ? "Following the device — click to stop" : "Follow the device")
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .glassPanel(cornerRadius: 9)
    }
}

// MARK: - Banners

struct Banners: View {
    @Environment(AppModel.self) private var model
    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 8) {
            if model.setupError == nil, model.hasRefreshedOnce, model.devices.isEmpty, model.session == nil {
                banner(icon: "iphone.slash", tint: .orange,
                       text: "No iPhone connected — plug it in with a data cable, unlock it and tap Trust.") {
                    Button("Help") { showHelp = true }
                        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                            ConnectionHelp().padding(16).frame(width: 340)
                        }
                }
            }
            if model.directionsState == .computing {
                banner(icon: model.travelMode.symbolName, tint: .accentColor,
                       text: "Finding a \(model.travelMode.label.lowercased()) route…") {
                    ProgressView().controlSize(.small)
                }
            }
            if model.hasPendingRouteChange {
                banner(icon: "arrow.triangle.2.circlepath", tint: .accentColor, text: "The route was edited.") {
                    Button("Apply Changes") { model.applyRouteChanges() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    private func banner<Accessory: View>(icon: String, tint: Color, text: String,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout)
            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: 20)
    }
}

struct DropHint: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 42))
            Text("Drop a GPX or KML file to import it as a route").font(.headline)
        }
        .padding(30)
        .glassPanel(cornerRadius: 18)
        .allowsHitTesting(false)
    }
}

// MARK: - Setup card

struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("pymobiledevice3 wasn't found").font(.title3.bold())
                    Text("It's the open-source tool that talks to the iPhone's developer services.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Install it once, then click Retry:").font(.callout)
            command("pipx install pymobiledevice3")
            Text("or, from the project folder:").font(.caption).foregroundStyle(.secondary)
            command("./setup.sh")
            if let error = model.setupError {
                DisclosureGroup("Details") {
                    Text(error).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            HStack {
                Button("Choose pymobiledevice3…") { model.choosePymobiledevice3() }
                Spacer()
                Button("Retry") {
                    model.resolveTool()
                    Task { await model.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .glassPanel(cornerRadius: 16)
    }

    private func command(_ text: String) -> some View {
        HStack {
            Text(text).font(.body.monospaced()).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}
