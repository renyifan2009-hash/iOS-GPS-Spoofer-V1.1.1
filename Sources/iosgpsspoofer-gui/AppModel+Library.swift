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
            offerUndo(ofRemoving: library.removeFavorite(near: target))
        } else {
            addFavorite(at: target, suggestedName: targetLabel)
        }
    }

    /// Remove a favorite. It's one click away from a mistake, so the note offers Undo.
    func removeFavoriteWithUndo(_ place: SavedPlace) {
        offerUndo(ofRemoving: library.removeFavorite(place.id))
    }

    private func offerUndo(ofRemoving removed: [FavoriteListEdit.Removed]) {
        guard !removed.isEmpty else { return }
        appendLog("Removed from favorites.", level: .info)
        showToast(Toast(symbol: "star.slash.fill", title: "Removed from Favorites",
                        subtitle: removed.count == 1 ? removed[0].place.name : "\(removed.count) places",
                        style: .info, actionTitle: "Undo",
                        action: { [weak self] in
                            self?.library.restoreFavorites(removed)
                            self?.appendLog("Put it back in favorites.", level: .info)
                        }),
                  duration: 7)
    }

    func addFavorite(at point: GeoPoint, suggestedName: String?) {
        guard let name = promptForText(title: "Add to Favorites",
                                       message: "Give this place a name.",
                                       defaultValue: suggestedName ?? "") else { return }
        let place = library.addFavorite(name: name, point: point)
        appendLog("Saved “\(place.name)” to favorites.", level: .success)
        showToast(Toast(symbol: "star.fill", title: "Added to Favorites", subtitle: place.name, style: .success))
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
        showToast(Toast(symbol: "doc.on.doc.fill", title: "Coordinates copied",
                        subtitle: Coordinate.format(point, precision: 6), style: .info))
    }

    /// Paste a coordinate or a Google/Apple Maps link as the target (or a waypoint).
    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            warn("Nothing to paste", "Copy coordinates or a maps link first.")
            return
        }
        guard let point = Coordinate.parsePoint(text), point.isValid else {
            warn("That isn't a place", "Paste coordinates like 37.33, -122.01 or a maps link.",
                 log: "The clipboard doesn't contain coordinates or a maps link.")
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
            // The file was chosen on purpose, but the stops it replaces may not be saved anywhere.
            guard okToDiscardRoute(title: "Replace the current route?",
                                   message: "\(unsavedRouteSentence) Importing “\(name)” replaces it.",
                                   discardTitle: "Replace") else { return }
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
            // Parts of the file that were left out (bad positions, far-apart trips) are said plainly.
            if let warning = imported.warning { appendLog(warning, level: .warning) }
            showToast(Toast(symbol: "square.and.arrow.down.fill", title: "Route imported",
                            subtitle: imported.warning ?? "\(name) · \(Format.distance(imported.length, units: prefs.units))",
                            style: imported.warning == nil ? .success : .warning), duration: imported.warning == nil ? 2.8 : 7)
        } catch {
            appendLog("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)", level: .error)
            showToast(Toast(symbol: "xmark.octagon.fill", title: "Couldn't import that file",
                            subtitle: url.lastPathComponent, style: .error))
        }
    }

    func exportRouteWithPanel() {
        guard waypoints.count >= 2 else {
            warn("Add at least two stops first", "Then you can export the route.",
                 log: "Add at least two waypoints before exporting.")
            return
        }
        // The track as played: a loop on roads includes the road back to the start.
        exportRoute(name: routeName ?? "Route", waypoints: waypoints.map(\.point),
                    track: followRoads ? routePath.points : nil)
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
            warn("Add at least two stops first", "Then you can save the route.",
                 log: "Add at least two waypoints before saving.")
            return
        }
        let suggestion = routeName ?? "Route \(library.routes.count + 1)"
        guard let name = promptForText(title: savedRouteID == nil ? "Save Route" : "Update Saved Route",
                                       message: "Saved routes appear in the sidebar.",
                                       defaultValue: suggestion) else { return }
        let route = SavedRoute(id: savedRouteID ?? UUID(), name: name, waypoints: waypoints.map(\.point),
                               followRoads: followRoads, travelMode: travelMode, loopMode: loopMode,
                               speed: effectiveRouteSpeed > 0 ? effectiveRouteSpeed : routeSpeed,
                               waits: waypoints.contains { $0.wait > 0 } ? waypoints.map(\.wait) : nil)
        library.saveRoute(route)
        savedRouteID = route.id
        routeName = route.name
        appendLog("Saved route “\(route.name)”.", level: .success)
        showToast(Toast(symbol: "bookmark.fill", title: "Route saved", subtitle: route.name, style: .success))
    }

    func loadSavedRoute(_ route: SavedRoute) {
        travelMode = route.travelMode
        followRoads = route.followRoads
        let waits = route.waits ?? []
        waypoints = route.waypoints.enumerated().map { i, point in
            Waypoint(point: point, wait: i < waits.count ? max(0, waits[i]) : 0)
        }
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

    // MARK: - Routes: asking first
    //
    // The mutators above stay plain (the screenshot harness calls them directly). The buttons
    // and menus call these, which ask before work that is saved nowhere would be thrown away.

    /// The route being edited, as the library would store it.
    var routeSnapshot: RouteSnapshot {
        RouteSnapshot(points: waypoints.map(\.point), waits: waypoints.map(\.wait), followRoads: followRoads,
                      travelMode: travelMode, loopMode: loopMode)
    }

    /// Stops that no saved route matches: replacing them would lose them for good.
    var hasUnsavedRoute: Bool {
        let saved = savedRouteID.flatMap { id in library.routes.first { $0.id == id } }.map(RouteSnapshot.init(saved:))
        return RouteDraftGuard.hasUnsavedWork(editing: routeSnapshot, savedCopy: saved)
    }

    /// What is at stake, for the question: a route never saved, or a saved one edited since.
    var unsavedRouteSentence: String {
        let wasSaved = savedRouteID.map { id in library.routes.contains { $0.id == id } } ?? false
        return wasSaved ? "You've changed this route since you saved it."
                        : "It has \(waypoints.count) stops and isn't saved."
    }

    /// Load a saved route, after asking if that replaces stops saved nowhere.
    func requestLoadSavedRoute(_ route: SavedRoute, thenStart: Bool = false) {
        guard okToDiscardRoute(title: "Replace the current route?",
                               message: "\(unsavedRouteSentence) Loading “\(route.name)” replaces it.",
                               discardTitle: "Replace") else { return }
        loadSavedRoute(route)
        if thenStart { startRoute() }
    }

    func requestClearWaypoints() {
        guard okToDiscardRoute(title: "Clear all \(waypoints.count) stops?",
                               message: "\(unsavedRouteSentence) You can't get it back.",
                               discardTitle: "Clear Route") else { return }
        clearWaypoints()
    }

    /// A saved route is gone for good once deleted, so this always asks.
    func requestDeleteSavedRoute(_ route: SavedRoute) {
        let choice = confirmDiscard(title: "Delete “\(route.name)”?",
                                    message: "This removes the saved route. You can't undo it.",
                                    discardTitle: "Delete")
        guard choice == .discard else { return }
        deleteSavedRoute(route)
        appendLog("Deleted the saved route “\(route.name)”.", level: .info)
    }

    /// True when it's fine to go ahead and replace the route being edited: it has nothing unsaved,
    /// or the person agreed (after saving it first, if they chose that).
    func okToDiscardRoute(title: String, message: String, discardTitle: String) -> Bool {
        guard hasUnsavedRoute else { return true }
        switch confirmDiscard(title: title, message: message, discardTitle: discardTitle, offerSave: true) {
        case .discard:
            return true
        case .cancel:
            return false
        case .saveFirst:
            saveRouteToLibrary()
            // They cancelled the name prompt: it still isn't saved, so leave things as they were.
            return !hasUnsavedRoute
        }
    }

    enum DiscardChoice { case discard, saveFirst, cancel }

    /// A warning with Cancel as the default button, so Return never throws anything away.
    func confirmDiscard(title: String, message: String, discardTitle: String, offerSave: Bool = false) -> DiscardChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        if offerSave { alert.addButton(withTitle: "Save Route First…") }
        let discard = alert.addButton(withTitle: discardTitle)
        discard.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .cancel
        case .alertSecondButtonReturn: return offerSave ? .saveFirst : .discard
        default: return .discard
        }
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
