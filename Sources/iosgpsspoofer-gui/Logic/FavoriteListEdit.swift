import Foundation
import SpooferCore

/// Taking places out of the favorites list in a way that can be put back exactly where they were.
enum FavoriteListEdit {
    struct Removed: Equatable {
        let index: Int
        let place: SavedPlace
    }

    /// `list` without the places `shouldRemove` picks, and what was taken out and from where.
    static func removing(from list: [SavedPlace], where shouldRemove: (SavedPlace) -> Bool)
        -> (list: [SavedPlace], removed: [Removed]) {
        var kept: [SavedPlace] = []
        var removed: [Removed] = []
        for (index, place) in list.enumerated() {
            if shouldRemove(place) { removed.append(Removed(index: index, place: place)) } else { kept.append(place) }
        }
        return (kept, removed)
    }

    /// Put removed places back at their old positions (as far as the list still reaches).
    /// A place that is already back (same id) is not added twice.
    static func restoring(_ removed: [Removed], into list: [SavedPlace]) -> [SavedPlace] {
        var result = list
        for item in removed.sorted(by: { $0.index < $1.index }) where !result.contains(where: { $0.id == item.place.id }) {
            result.insert(item.place, at: min(item.index, result.count))
        }
        return result
    }
}
