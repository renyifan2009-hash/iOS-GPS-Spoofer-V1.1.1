import AppKit
import Foundation
import SpooferCore
import UniformTypeIdentifiers

extension AppModel {

    // MARK: - Favorites & recents

    var targetIsFavorite: Bool {
        guard let target else { return false }
        return library.isFavorite(target)
    }

    /// Star / un-star the teleport target.
    func toggleFavoriteForTarget() {
        guard let target else { return }
        if library.isFavorite(target) {
            library.removeFavorite(near: target)
            appendLog("Removed from favorites.", level: .info)
        } else {
            addFavorite(at: target, suggestedName: targetLabel)
        }
    }

    func addFavorite(at point: GeoPoint, suggestedName: String?) {
        guard let name = promptForText(title: "Add to Favorites",
                                       message: "Name this place. The CLI can use it as @name.",
                                       defaultValue: suggestedName ?? "") else { return }
        let place = library.addFavorite(name: name, point: point)
        appendLog("Saved “\(place.name)” to favorites.", level: .success)
    }

    func renameFavorite(_ place: SavedPlace) {
        guard let name = promptForText(title: "Rename Favorite", message: "", defaultValue: place.name) else { return }
        library.renameFavorite(place.id, to: name)
    }

    /// Select a saved place as the target; optionally go there right away.
    func useSavedPlace(_ place: SavedPlace, teleportNow: Bool) {
        if mode == .route {
            addWaypoint(place.point)
            focus(on: place.point)
            return
        }
        setTarget(place.point, name: place.name, focus: true)
        if teleportNow { teleport(to: place.point, name: place.name) }
    }

    // MARK: - Clipboard & sharing

    func copyCoordinates(_ point: GeoPoint) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Coordinate.format(point, precision: 6), forType: .string)
        appendLog("Copied \(Coordinate.format(point, precision: 6)).", level: .info)
    }

    /// Paste a coordinate or a Google/Apple Maps link as the target (or a waypoint).
    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        guard let point = Coordinate.parsePoint(text), point.isValid else {
            appendLog("The clipboard doesn't contain coordinates or a maps link.", level: .warning)
            return
        }
        if mode == .route {
            addWaypoint(point)
            focus(on: point)
        } else {
            setTarget(point, focus: true)
        }
    }

    func openInMaps(_ point: GeoPoint, google: Bool) {
        let ll = "\(point.latitude),\(point.longitude)"
        let urlString = google
            ? "https://www.google.com/maps/search/?api=1&query=\(ll)"
            : "https://maps.apple.com/?ll=\(ll)&q=Simulated%20location"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Routes: files

    static var routeFileTypes: [UTType] {
        RouteImporter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    func importRouteWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import a Route"
        panel.allowedContentTypes = Self.routeFileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importRoute(from: url)
    }

    func importRoute(from url: URL) {
        do {
            let imported = try RouteImporter.load(contentsOf: url)
            let name = imported.name ?? url.deletingPathExtension().lastPathComponent
            if imported.points.count == 1, let only = imported.points.first {
                mode = .teleport
                setTarget(only, name: name, focus: true)
                appendLog("Imported the place “\(name)”.", level: .success)
                return
            }
            var points = imported.points
            if !imported.isWaypointList || points.count > 200 {
                points = RouteSimplifier.simplify(points, maxPoints: 200)
            }
            followRoads = false   // a recorded track already follows its roads
            waypoints = points.map { Waypoint(point: $0) }
            routeName = name
            savedRouteID = nil
            if let speed = imported.averageSpeed, (0.3...70).contains(speed) {
                pacing = .speed
                routeSpeed = speed
            }
            mode = .route
            fitMap()
            var message = "Imported “\(name)”: \(Format.distance(imported.length, units: prefs.units))"
            if points.count < imported.points.count {
                message += ", simplified from \(imported.points.count) to \(points.count) points"
            }
            if let speed = imported.averageSpeed {
                message += ", recorded at \(Format.speed(speed, units: prefs.units))"
            }
            appendLog(message + ".", level: .success)
        } catch {
            appendLog("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)", level: .error)
        }
    }

    func exportRouteWithPanel() {
        guard waypoints.count >= 2 else {
            appendLog("Add at least two waypoints before exporting.", level: .warning)
            return
        }
        exportRoute(name: routeName ?? "Route", waypoints: waypoints.map(\.point),
                    track: followRoads ? routeGeometry : nil)
    }

    func exportRoute(name: String, waypoints: [GeoPoint], track: [GeoPoint]?) {
        let panel = NSSavePanel()
        panel.title = "Export Route as GPX"
        panel.nameFieldStringValue = "\(name).gpx"
        if let gpx = UTType(filenameExtension: "gpx") { panel.allowedContentTypes = [gpx] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RouteBuilder.exportGPX(name: name, waypoints: waypoints, track: track)
                .write(to: url, atomically: true, encoding: .utf8)
            appendLog("Exported \(url.lastPathComponent).", level: .success)
        } catch {
            appendLog("Couldn't export: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Routes: library

    func saveRouteToLibrary() {
        guard waypoints.count >= 2 else {
            appendLog("Add at least two waypoints before saving.", level: .warning)
            return
        }
        let suggestion = routeName ?? "Route \(library.routes.count + 1)"
        guard let name = promptForText(title: savedRouteID == nil ? "Save Route" : "Update Saved Route",
                                       message: "Saved routes appear in the sidebar.",
                                       defaultValue: suggestion) else { return }
        let route = SavedRoute(id: savedRouteID ?? UUID(), name: name, waypoints: waypoints.map(\.point),
                               followRoads: followRoads, travelMode: travelMode, loopMode: loopMode,
                               speed: effectiveRouteSpeed > 0 ? effectiveRouteSpeed : routeSpeed)
        library.saveRoute(route)
        savedRouteID = route.id
        routeName = route.name
        appendLog("Saved route “\(route.name)”.", level: .success)
    }

    func loadSavedRoute(_ route: SavedRoute) {
        travelMode = route.travelMode
        followRoads = route.followRoads
        waypoints = route.waypoints.map { Waypoint(point: $0) }
        loopMode = route.loopMode
        pacing = .speed
        routeSpeed = route.speed
        routeName = route.name
        savedRouteID = route.id
        mode = .route
        fitMap()
    }

    func renameSavedRoute(_ route: SavedRoute) {
        guard let name = promptForText(title: "Rename Route", message: "", defaultValue: route.name) else { return }
        library.renameRoute(route.id, to: name)
        if savedRouteID == route.id { routeName = name }
    }

    func deleteSavedRoute(_ route: SavedRoute) {
        library.removeRoute(route.id)
        if savedRouteID == route.id { savedRouteID = nil }
    }

    // MARK: - Small AppKit helpers

    /// A modal text prompt; nil when cancelled or left empty.
    func promptForText(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Let the user point at a pymobiledevice3 executable.
    func choosePymobiledevice3() {
        let panel = NSOpenPanel()
        panel.title = "Choose pymobiledevice3"
        panel.message = "Select the pymobiledevice3 executable (or a Python interpreter that has it installed)."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.pymobiledevice3Path = url.path
        resolveTool()
        if let setupError {
            appendLog("That didn't work: \(setupError)", level: .error)
        } else {
            appendLog("Using pymobiledevice3 at \(url.path).", level: .success)
            Task { await refresh() }
        }
    }

    func revealDataFolder() {
        let dir = AppSupport.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
