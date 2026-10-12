import SpooferCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            MainView()
        }
        .task { model.bootstrap() }
        .sheet(isPresented: $model.showWelcome, onDismiss: { model.finishWelcome() }) {
            WelcomeView()
                .environment(model)
                .environment(Preferences.shared)
                .tint(Brand.accent)
        }
        .sheet(isPresented: $model.showConnectionHelp) {
            ConnectionHelpSheet()
                .tint(Brand.accent)
        }
        .sheet(isPresented: $model.showPairingFile) {
            PairingFileSheet()
                .environment(model)
                .tint(Brand.accent)
        }
        .sheet(isPresented: Binding(get: { PhoneInstaller.shared.isPresented },
                                    set: { PhoneInstaller.shared.isPresented = $0 })) {
            PhoneInstallSheet()
                .environment(model)
                .tint(Brand.accent)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(Preferences.self) private var prefs

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedUDID) {
            Section {
                if model.sidebarDevices.isEmpty {
                    NoDeviceRow(state: model.sidebarEmptyState)
                }
                ForEach(model.sidebarDevices) { row in
                    DeviceRow(device: row.device, connected: row.connected,
                              spoofing: model.session?.device.udid == row.device.udid,
                              status: model.statusDisplay)
                        .tag(row.device.udid)
                }
            } header: {
                HStack {
                    Text("Devices")
                    Spacer()
                    if model.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            // With no helper there is nothing to scan with: say so, don't do nothing.
                            if model.pmd == nil { model.explain(.helperMissing) } else { Task { await model.refresh() } }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Rescan for devices (also automatic every \(Int(prefs.autoRefreshInterval)) s)")
                    }
                }
            }

            Section("Favorites") {
                if library.favorites.isEmpty {
                    EmptyRow(symbol: "star", text: "Star a place (⌘D) to keep it here.")
                }
                ForEach(library.favorites) { place in
                    PlaceRow(name: place.name, point: place.point, symbol: "star.fill", colors: TileColors.yellow,
                             units: prefs.units, distanceFrom: model.devicePosition)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.useSavedPlace(place, teleportNow: true) }
                        .onTapGesture { model.useSavedPlace(place, teleportNow: false) }
                        .contextMenu {
                            Button("Teleport Here") { model.useSavedPlace(place, teleportNow: true) }
                            Button("Add as Waypoint") {
                                model.mode = .route
                                model.addWaypoint(place.point)
                            }
                            Divider()
                            Button("Rename…") { model.renameFavorite(place) }
                            Button("Copy Coordinates") { model.copyCoordinates(place.point) }
                            Divider()
                            Button("Remove from Favorites", role: .destructive) { model.removeFavoriteWithUndo(place) }
                        }
                        .help("Click to select · double-click to teleport")
                }
                .onMove { library.moveFavorites(from: $0, to: $1) }
            }

            if !library.recents.isEmpty {
                Section {
                    ForEach(library.recents.prefix(10)) { place in
                        PlaceRow(name: place.name, point: place.point, symbol: "clock.fill", colors: TileColors.gray,
                                 units: prefs.units, subtitle: place.created.formatted(.relative(presentation: .named)))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.useSavedPlace(place, teleportNow: true) }
                            .onTapGesture { model.useSavedPlace(place, teleportNow: false) }
                            .contextMenu {
                                Button("Teleport Here") { model.useSavedPlace(place, teleportNow: true) }
                                Button("Add to Favorites…") { model.addFavorite(at: place.point, suggestedName: place.name) }
                                Button("Copy Coordinates") { model.copyCoordinates(place.point) }
                                Divider()
                                Button("Remove", role: .destructive) { library.removeRecent(place.id) }
                            }
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") { library.clearRecents() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }

            Section("Saved Routes") {
                if library.routes.isEmpty {
                    EmptyRow(symbol: "bookmark", text: "Build a route, then save it (⌘S).")
                }
                ForEach(library.routes) { route in
                    RouteRow(route: route, units: prefs.units, isLoaded: model.savedRouteID == route.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.requestLoadSavedRoute(route) }
                        .contextMenu {
                            Button("Load") { model.requestLoadSavedRoute(route) }
                            Button("Load & Start") { model.requestLoadSavedRoute(route, thenStart: true) }
                            Divider()
                            Button("Rename…") { model.renameSavedRoute(route) }
                            Button("Export GPX…") {
                                model.exportRoute(name: route.name, waypoints: route.waypoints, track: nil)
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { model.requestDeleteSavedRoute(route) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIconImage.shared)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("AnyWhere").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                EngineBadge(engine: model.sessionEngine, status: model.engineStatus)
            }
            Spacer()
            Button {
                model.showWelcome = true
            } label: {
                Image(systemName: "checklist")
            }
            .buttonStyle(.borderless)
            .help("Setup checklist")
            Button {
                model.openPairingFileAssistant()
            } label: {
                Image(systemName: "iphone.and.arrow.forward")
            }
            .buttonStyle(.borderless)
            .help("Pairing file for the iPhone app (⇧⌘K)")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// The rendered app icon, drawn once.
@MainActor
enum AppIconImage {
    static let shared = AppIconRenderer.image(size: 256)
}

struct DeviceRow: View {
    let device: Device
    let connected: Bool
    let spoofing: Bool
    let status: StatusDisplay

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                IconTile(symbol: device.symbolName,
                         colors: spoofing ? TileColors.brand : (connected ? TileColors.teal : TileColors.gray),
                         size: 30)
                Image(systemName: device.isUSB ? "cable.connector" : "wifi")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2.5)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .offset(x: 4, y: 3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(connected ? "\(device.modelName) · iOS \(device.productVersion)" : "Disconnected — waiting…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if spoofing {
                HStack(spacing: 4) {
                    PulsingDot(color: status.tint, size: 6, active: status.live)
                    Text(status.title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(status.tint)
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(connected ? 1 : 0.6)
    }
}

/// What the Devices list says with no iPhone in it. The words depend on why: the helper isn't
/// installed (nothing was looked for), the helper can't list iPhones, or there just isn't one.
struct NoDeviceRow: View {
    let state: SidebarEmptyState
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .searching:
                ProgressView().controlSize(.small)
                Text("Looking for devices…").foregroundStyle(.secondary)
            case .helperMissing:
                IconTile(symbol: "wrench.and.screwdriver.fill", colors: TileColors.orange, size: 22)
                Text("Install the helper first").foregroundStyle(.secondary)
                    .help("The card on the map has an Install button.")
            case .listFailed(let message):
                IconTile(symbol: "exclamationmark.triangle.fill", colors: TileColors.orange, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Can't look for iPhones").foregroundStyle(.secondary)
                    Text(message).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                }
                .help(message)
            case .noIPhone:
                IconTile(symbol: "iphone.slash", colors: TileColors.gray, size: 22)
                Text("No iPhone connected").foregroundStyle(.secondary)
                Spacer()
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("How to connect an iPhone")
                .popover(isPresented: $showHelp, arrowEdge: .trailing) { ConnectionHelp().padding(18).frame(width: 360) }
            }
        }
        .font(.callout)
    }
}

struct EmptyRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tertiary).frame(width: 20)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Step-by-step help for connecting an iPhone.
struct ConnectionHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your iPhone").font(Brand.title(17))
            step(1, "cable.connector", "Use a USB **data** cable, plugged straight into the Mac (not a hub).")
            step(2, "hand.tap", "Unlock the iPhone, tap **Trust**, and enter your passcode.")
            step(3, "hammer", "Turn on **Developer Mode**: Settings ▸ Privacy & Security ▸ Developer Mode. The iPhone restarts. Confirm with **Turn On**. Don't see the switch? Click **Show the Switch** in AnyWhere, then look again.")
            step(4, "lock.open", "Keep the iPhone unlocked and this Mac online the first time you teleport. AnyWhere sets up Apple's developer support then. It needs the internet once.")
            Text("Wi-Fi works too once the phone has been paired over USB: Finder ▸ your iPhone ▸ “Show this iPhone when on Wi-Fi”.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ n: Int, _ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 24, height: 24)
                Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: symbol).foregroundStyle(.tertiary)
        }
    }
}

struct ConnectionHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ConnectionHelp()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct PlaceRow: View {
    let name: String
    let point: GeoPoint
    let symbol: String
    let colors: [Color]
    let units: UnitSystem
    var subtitle: String?
    var distanceFrom: GeoPoint?

    var body: some View {
        HStack(spacing: 9) {
            IconTile(symbol: symbol, colors: colors, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var detail: String {
        if let subtitle { return subtitle }
        if let distanceFrom { return "\(Format.distance(Geo.distance(distanceFrom, point), units: units)) away" }
        return Format.coordinate(point, precision: 4)
    }
}

struct RouteRow: View {
    let route: SavedRoute
    let units: UnitSystem
    let isLoaded: Bool

    var body: some View {
        HStack(spacing: 9) {
            IconTile(symbol: route.loopMode == .once ? "point.topleft.down.to.point.bottomright.curvepath" : route.loopMode.symbolName,
                     colors: isLoaded ? TileColors.brand : TileColors.purple, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(route.name).lineLimit(1).fontWeight(isLoaded ? .semibold : .regular)
                Text("\(Format.distance(Geo.length(of: route.waypoints), units: units)) · \(route.waypoints.count) stops · \(Format.speed(route.speed, units: units))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
