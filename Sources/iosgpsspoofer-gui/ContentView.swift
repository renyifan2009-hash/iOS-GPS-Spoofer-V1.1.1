import SpooferCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            MainView()
        }
        .task { model.bootstrap() }
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
                    NoDeviceRow(searching: !model.hasRefreshedOnce)
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
                            Task { await model.refresh() }
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
                    Text("Star a place (⌘D) to keep it here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(library.favorites) { place in
                    PlaceRow(name: place.name, point: place.point, symbol: "star.fill", tint: .yellow, units: prefs.units,
                             distanceFrom: model.devicePosition)
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
                            Button("Remove from Favorites", role: .destructive) { library.removeFavorite(place.id) }
                        }
                        .help("Click to select · double-click to teleport")
                }
                .onMove { library.moveFavorites(from: $0, to: $1) }
            }

            if !library.recents.isEmpty {
                Section {
                    ForEach(library.recents.prefix(12)) { place in
                        PlaceRow(name: place.name, point: place.point, symbol: "clock", tint: .secondary, units: prefs.units,
                                 subtitle: place.created.formatted(.relative(presentation: .named)))
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
                    Text("Build a route, then Save it from the Route panel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(library.routes) { route in
                    RouteRow(route: route, units: prefs.units, isLoaded: model.savedRouteID == route.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.loadSavedRoute(route) }
                        .contextMenu {
                            Button("Load") { model.loadSavedRoute(route) }
                            Button("Load & Start") {
                                model.loadSavedRoute(route)
                                model.startRoute()
                            }
                            Divider()
                            Button("Rename…") { model.renameSavedRoute(route) }
                            Button("Export GPX…") {
                                model.exportRoute(name: route.name, waypoints: route.waypoints, track: nil)
                            }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteSavedRoute(route) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct DeviceRow: View {
    let device: Device
    let connected: Bool
    let spoofing: Bool
    let status: StatusDisplay

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: device.symbolName)
                    .font(.title2)
                    .frame(width: 26)
                    .foregroundStyle(connected ? Color.accentColor : Color.secondary)
                Image(systemName: device.isUSB ? "cable.connector" : "wifi")
                    .font(.system(size: 8, weight: .bold))
                    .padding(2)
                    .background(.background, in: Circle())
                    .offset(x: 4, y: 2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName).fontWeight(.medium).lineLimit(1)
                Text(connected ? "\(device.modelName) · iOS \(device.productVersion)" : "Disconnected — waiting…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if spoofing {
                Circle()
                    .fill(status.tint)
                    .frame(width: 8, height: 8)
                    .help(status.title)
            }
        }
        .padding(.vertical, 3)
        .opacity(connected ? 1 : 0.65)
    }
}

struct NoDeviceRow: View {
    let searching: Bool
    @State private var showHelp = false

    var body: some View {
        HStack(spacing: 8) {
            if searching {
                ProgressView().controlSize(.small)
                Text("Looking for devices…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "iphone.slash").foregroundStyle(.secondary)
                Text("No iPhone connected").foregroundStyle(.secondary)
                Spacer()
                Button {
                    showHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showHelp, arrowEdge: .trailing) { ConnectionHelp().padding(16).frame(width: 340) }
            }
        }
        .font(.callout)
    }
}

/// Checklist shown when no device is found.
struct ConnectionHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your iPhone").font(.headline)
            step(1, "Use a USB **data** cable, plugged straight into the Mac.")
            step(2, "Unlock the iPhone and tap **Trust**, then enter the passcode.")
            step(3, "Turn on **Developer Mode**: Settings ▸ Privacy & Security ▸ Developer Mode (the phone restarts).")
            step(4, "Keep the phone unlocked for the first run — the developer disk image is mounted automatically.")
            Text("Wi-Fi works too once the phone has been paired over USB (Finder ▸ “Show this iPhone when on Wi-Fi”).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.2), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PlaceRow: View {
    let name: String
    let point: GeoPoint
    let symbol: String
    let tint: Color
    let units: UnitSystem
    var subtitle: String?
    var distanceFrom: GeoPoint?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
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
        HStack(spacing: 8) {
            Image(systemName: route.loopMode == .once ? "point.topleft.down.to.point.bottomright.curvepath" : route.loopMode.symbolName)
                .foregroundStyle(isLoaded ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(route.name).lineLimit(1).fontWeight(isLoaded ? .semibold : .regular)
                Text("\(Format.distance(Geo.length(of: route.waypoints), units: units)) · \(route.waypoints.count) pts · \(Format.speed(route.speed, units: units))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
