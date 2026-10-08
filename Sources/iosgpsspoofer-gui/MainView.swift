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
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if let toast = model.toast {
                        ToastView(toast: toast)
                            .id(toast.id)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Banners()
                }
                .padding(.top, 72)
                .animation(.spring(duration: 0.35), value: model.toast)
            }
            .overlay(alignment: .bottom) {
                if model.hasSession {
                    HUDView()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if model.mode == .joystick {
                    JoystickPanel()
                        .padding(16)
                        .padding(.bottom, model.hasSession ? 128 : 0)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                HStack(alignment: .top, spacing: 12) {
                    SearchBar(search: search)
                        .frame(maxWidth: 430)
                    Spacer(minLength: 12)
                    MapControls()
                }
                .padding(14)
            }
            .overlay {
                if model.setupError != nil {
                    MapScrim { SetupCard() }
                } else if model.shouldShowConnectCard {
                    MapScrim { ConnectCard() }
                } else if dropTargeted {
                    DropHint()
                }
            }
            .animation(.snappy(duration: 0.3), value: model.hasSession)
            .animation(.snappy(duration: 0.3), value: model.mode)
            .animation(.easeOut(duration: 0.25), value: model.shouldShowConnectCard)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { RouteImporter.supportedExtensions.contains($0.pathExtension.lowercased()) })
                else { return false }
                model.importRoute(from: url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .inspector(isPresented: $model.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 330, ideal: 370, max: 480)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ModeSwitcher(mode: $model.mode)
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
        guard let device = model.activeDevice else { return "No iPhone connected" }
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

/// Teleport · Route · Joystick, with a sliding gradient selection.
struct ModeSwitcher: View {
    @Binding var mode: AppModel.Mode
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Mode.allCases) { item in
                let selected = item == mode
                Button {
                    withAnimation(.snappy(duration: 0.28)) { mode = item }
                } label: {
                    Label(item.label, systemImage: item.symbolName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Brand.gradient)
                                    .shadow(color: Brand.indigo.opacity(0.35), radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help(for: item))
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private func help(for item: AppModel.Mode) -> String {
        switch item {
        case .teleport: return "Jump to any place (⌘1)"
        case .route: return "Travel along a route (⌘2)"
        case .joystick: return "Steer live with a joystick (⌘3)"
        }
    }
}

/// Dims the map behind a centred card.
struct MapScrim<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.18)).ignoresSafeArea()
            content
        }
        .transition(.opacity)
    }
}

// MARK: - Search

struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @Bindable var search: PlaceSearch
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
                TextField("Search a place, paste coordinates or a maps link", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
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
                } else {
                    Text("⌘F")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 42)

            if !search.query.isEmpty && !search.suggestions.isEmpty {
                Divider().padding(.horizontal, 8)
                VStack(spacing: 1) {
                    ForEach(Array(search.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        suggestionRow(suggestion, highlighted: index == search.highlighted)
                            .onTapGesture { choose(index) }
                            .onHover { inside in if inside { search.highlighted = index } }
                    }
                }
                .padding(6)
            }
        }
        .glassPanel(cornerRadius: 14)
        .onChange(of: model.searchFocusRequest) { focused = true }
    }

    private func suggestionRow(_ suggestion: PlaceSearch.Suggestion, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: suggestion.symbolName,
                     colors: suggestion.symbolName == "star.fill" ? TileColors.yellow
                        : (suggestion.symbolName == "scope" ? TileColors.purple : TileColors.brand),
                     size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(highlighted ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if highlighted {
                Image(systemName: "return")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.gradient)
            }
        }
        .contentShape(Rectangle())
    }

    private func choose(_ index: Int) {
        guard search.suggestions.indices.contains(index) else { return }
        let suggestion = search.suggestions[index]
        Task {
            guard let place = await search.resolve(suggestion) else {
                model.showToast(Toast(symbol: "questionmark.circle.fill", title: "Couldn't locate that place",
                                      subtitle: suggestion.title, style: .warning))
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
        VStack(spacing: 6) {
            Menu {
                Picker("Map Style", selection: $prefs.mapStyle) {
                    ForEach(MapStyle.allCases) { style in
                        Label(style.label, systemImage: style.symbolName).tag(style)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: prefs.mapStyle.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .help("Map style")

            Button {
                model.fitMap()
            } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(CircleIconButtonStyle())
            .help("Fit the map to what matters (⌘0)")

            Button {
                prefs.followDevice.toggle()
            } label: {
                Image(systemName: prefs.followDevice ? "location.fill" : "location")
            }
            .buttonStyle(CircleIconButtonStyle(prominent: prefs.followDevice))
            .help(prefs.followDevice ? "Following the device — click to stop" : "Follow the device")
        }
        .padding(5)
        .glassPanel(cornerRadius: 22)
    }
}

// MARK: - Banners

struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let device = model.selectedDevice, model.developerModeEnabled == false, model.session == nil {
                banner(icon: "hammer.fill", colors: TileColors.orange,
                       text: "Developer Mode is off on \(device.deviceName).") {
                    Button("How to turn it on") { model.showConnectionHelp = true }
                        .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                }
            }
            if model.directionsState == .computing {
                banner(icon: model.travelMode.symbolName, colors: TileColors.brand,
                       text: "Finding a \(model.travelMode.label.lowercased()) route…") {
                    ProgressView().controlSize(.small)
                }
            }
            if model.hasPendingRouteChange {
                banner(icon: "arrow.triangle.2.circlepath", colors: TileColors.brand, text: "You edited the route.") {
                    Button("Apply Changes") { model.applyRouteChanges() }
                        .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
                }
            }
        }
    }

    private func banner<Accessory: View>(icon: String, colors: [Color], text: String,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: icon, colors: colors, size: 24)
            Text(text).font(.system(size: 13, weight: .medium))
            accessory()
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .glassPanel(cornerRadius: 22)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct DropHint: View {
    var body: some View {
        VStack(spacing: 12) {
            IconTile(symbol: "square.and.arrow.down.fill", size: 56)
            Text("Drop to import the route").font(Brand.title(18))
            Text("GPX or KML — tracks, routes or waypoints").font(.callout).foregroundStyle(.secondary)
        }
        .padding(32)
        .glassPanel(cornerRadius: 22)
        .allowsHitTesting(false)
    }
}

// MARK: - Connect card

/// Shown over the map until an iPhone appears.
struct ConnectCard: View {
    @Environment(AppModel.self) private var model
    @State private var animate = false

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                IconTile(symbol: "laptopcomputer", colors: TileColors.gray, size: 58)
                HStack(spacing: 7) {
                    ForEach(0..<5) { i in
                        Circle()
                            .fill(Brand.gradient)
                            .frame(width: 7, height: 7)
                            .opacity(animate ? 1 : 0.2)
                            .scaleEffect(animate ? 1 : 0.6)
                            .animation(.easeInOut(duration: 0.7).repeatForever().delay(Double(i) * 0.14), value: animate)
                    }
                }
                IconTile(symbol: "iphone", colors: TileColors.brand, size: 58)
            }
            VStack(spacing: 6) {
                Text("Connect your iPhone").font(Brand.title(24))
                Text("Plug it into this Mac with a USB cable, unlock it and tap **Trust**. It appears here automatically.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.setupChecks) { SetupCheckRow(check: $0) }
            }
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Button("Setup help") { model.showConnectionHelp = true }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                Spacer()
                Button("Plan without a device") { model.connectCardDismissed = true }
                    .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
            }
        }
        .padding(28)
        .frame(width: 470)
        .glassPanel(cornerRadius: 24)
        .onAppear { animate = true }
    }
}

// MARK: - Setup card

struct SetupCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "wrench.and.screwdriver.fill", colors: TileColors.orange, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("One quick install").font(Brand.title(20))
                    Text("iOS GPS Spoofer talks to your iPhone through the free, open-source pymobiledevice3.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Install it once in Terminal, then click Check Again:").font(.callout.weight(.medium))
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
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                Spacer()
                Button("Check Again") {
                    model.resolveTool()
                    Task { await model.refresh() }
                }
                .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 480)
        .glassPanel(cornerRadius: 22)
    }

    private func command(_ text: String) -> some View {
        HStack {
            Text("$").foregroundStyle(.tertiary)
            Text(text).textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                model.showToast(Toast(symbol: "doc.on.doc.fill", title: "Copied", subtitle: text, style: .info))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(10)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .foregroundStyle(Color.white)
    }
}
