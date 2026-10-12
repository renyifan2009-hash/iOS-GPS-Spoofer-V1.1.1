import Foundation
import Observation
import SpooferCore
import SwiftUI   // Array.move(fromOffsets:toOffset:)

/// Favorites, recent locations and saved routes, persisted to
/// `~/Library/Application Support/AnyWhere/library.json` (shared with the
/// CLI, which understands `@Favorite` names).
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var data: LibraryData

    var favorites: [SavedPlace] { data.favorites }
    var recents: [SavedPlace] { data.recents }
    var routes: [SavedRoute] { data.routes }

    private init() {
        let loaded = LibraryFile.loadWithReport()
        data = loaded.library
        loadReport = loaded.report
    }

    /// What reading the library file found: entries that couldn't be read are skipped (and the file is
    /// copied first), never silently thrown away. Said once the app is up (`reportLoadProblems`).
    private let loadReport: LibraryFile.LoadReport

    /// Tell the person if something in their saved places couldn't be read.
    func reportLoadProblems() {
        let model = AppModel.shared
        if loadReport.droppedEntries > 0 {
            let n = loadReport.droppedEntries
            model.appendLog("\(n) saved place\(n == 1 ? "" : "s") or route\(n == 1 ? "" : "s") couldn't be read and "
                + "\(n == 1 ? "was" : "were") left out. A copy of the file was kept next to it.", level: .warning)
        }
        if loadReport.unreadable {
            model.appendLog("Your saved places file couldn't be read, so it was not changed. Open Settings or Finder to look at it.", level: .warning)
        } else if loadReport.movedAside != nil {
            model.appendLog("Your saved places file was damaged. It was set aside and a fresh one started.", level: .warning)
        }
    }

    private func persist() {
        do { try LibraryFile.save(data) } catch {
            AppModel.shared.appendLog("Couldn't save the library: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: Favorites

    func isFavorite(_ point: GeoPoint) -> Bool { data.favorite(near: point) != nil }

    @discardableResult
    func addFavorite(name: String, point: GeoPoint) -> SavedPlace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = SavedPlace(name: trimmed.isEmpty ? Coordinate.format(point, precision: 4) : trimmed, point: point)
        data.favorites.insert(place, at: 0)
        persist()
        return place
    }

    /// What was removed comes back, so a note can offer Undo.
    @discardableResult
    func removeFavorite(near point: GeoPoint) -> [FavoriteListEdit.Removed] {
        let result = FavoriteListEdit.removing(from: data.favorites) { Geo.distance($0.point, point) < 15 }
        data.favorites = result.list
        persist()
        return result.removed
    }

    @discardableResult
    func removeFavorite(_ id: UUID) -> [FavoriteListEdit.Removed] {
        let result = FavoriteListEdit.removing(from: data.favorites) { $0.id == id }
        data.favorites = result.list
        persist()
        return result.removed
    }

    /// Undo of a removal: the places go back where they were.
    func restoreFavorites(_ removed: [FavoriteListEdit.Removed]) {
        data.favorites = FavoriteListEdit.restoring(removed, into: data.favorites)
        persist()
    }

    func renameFavorite(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = data.favorites.firstIndex(where: { $0.id == id }) else { return }
        data.favorites[i].name = trimmed
        persist()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        data.favorites.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: Recents

    func recordRecent(name: String, point: GeoPoint) {
        data.recordRecent(SavedPlace(name: name, point: point))
        persist()
    }

    func removeRecent(_ id: UUID) {
        data.recents.removeAll { $0.id == id }
        persist()
    }

    func clearRecents() {
        data.recents.removeAll()
        persist()
    }

    // MARK: Routes

    /// Insert, or replace the route with the same id.
    func saveRoute(_ route: SavedRoute) {
        if let i = data.routes.firstIndex(where: { $0.id == route.id }) {
            data.routes[i] = route
        } else {
            data.routes.insert(route, at: 0)
        }
        persist()
    }

    func renameRoute(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = data.routes.firstIndex(where: { $0.id == id }) else { return }
        data.routes[i].name = trimmed
        persist()
    }

    func removeRoute(_ id: UUID) {
        data.routes.removeAll { $0.id == id }
        persist()
    }
}
