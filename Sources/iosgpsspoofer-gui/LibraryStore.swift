import Foundation
import Observation
import SpooferCore

/// Favorites, recent locations and saved routes, persisted to
/// `~/Library/Application Support/iOS GPS Spoofer/library.json` (shared with the
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
        data = LibraryFile.load()
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

    func removeFavorite(near point: GeoPoint) {
        data.favorites.removeAll { Geo.distance($0.point, point) < 15 }
        persist()
    }

    func removeFavorite(_ id: UUID) {
        data.favorites.removeAll { $0.id == id }
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
