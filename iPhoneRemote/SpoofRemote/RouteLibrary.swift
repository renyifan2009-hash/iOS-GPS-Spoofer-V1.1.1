import Foundation
import Observation
import PhoneOnlyCore

/// Routes saved by name, and the last few that were driven. Kept in this iPhone's defaults; a route only
/// leaves the iPhone when it is driven (it goes to the Mac). The rules for what is kept live in
/// `PhoneOnlyCore.SavedRoute`, which has the tests.
@MainActor
@Observable
final class RouteLibrary {
    private(set) var saved: [SavedRoute] = []
    private(set) var recents: [SavedRoute] = []

    static let maxRecents = 15
    static let maxSaved = 100

    @ObservationIgnored private let defaults: UserDefaults
    private static let savedKey = "savedRoutes"
    private static let recentsKey = "recentRoutes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = SavedRoute.decodeList(defaults.data(forKey: Self.savedKey))
        recents = SavedRoute.decodeList(defaults.data(forKey: Self.recentsKey))
    }

    /// Keep this route under its name. A name that is already saved is replaced, not duplicated.
    @discardableResult
    func save(_ route: SavedRoute) -> SavedRoute? {
        guard route.isUsable else { return nil }
        var route = route
        route.name = SavedRoute.cleanName(route.name)
        if let index = saved.firstIndex(where: { $0.name.caseInsensitiveCompare(route.name) == .orderedSame }) {
            route.id = saved[index].id
            saved.remove(at: index)
        }
        saved.insert(route, at: 0)
        if saved.count > Self.maxSaved { saved.removeLast(saved.count - Self.maxSaved) }
        persist()
        return route
    }

    /// Note a route that was just driven, so it can be run again. The same stops twice are one entry.
    func recordRecent(_ route: SavedRoute) {
        guard route.isUsable else { return }
        recents.removeAll { $0.isSameRoute(as: route) }
        recents.insert(route, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        persist()
    }

    func rename(_ id: SavedRoute.ID, to name: String) {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[index].name = SavedRoute.cleanName(name)
        persist()
    }

    func removeSaved(at offsets: IndexSet) {
        saved.remove(atOffsets: offsets)
        persist()
    }

    func removeRecents(at offsets: IndexSet) {
        recents.remove(atOffsets: offsets)
        persist()
    }

    func clearRecents() {
        recents.removeAll()
        persist()
    }

    func isSaved(_ route: SavedRoute) -> Bool {
        saved.contains { $0.isSameRoute(as: route) }
    }

    private func persist() {
        if let data = SavedRoute.encodeList(saved) { defaults.set(data, forKey: Self.savedKey) }
        if let data = SavedRoute.encodeList(recents) { defaults.set(data, forKey: Self.recentsKey) }
    }
}
