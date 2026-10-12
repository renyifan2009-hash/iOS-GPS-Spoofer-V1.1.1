import Foundation
import SpooferCore

/// What a route in the editor amounts to, for one question: is it saved anywhere?
struct RouteSnapshot: Equatable {
    var points: [GeoPoint]
    /// Seconds to wait at each stop, one per point.
    var waits: [TimeInterval]
    var followRoads: Bool
    var travelMode: TravelMode
    var loopMode: LoopMode

    init(points: [GeoPoint], waits: [TimeInterval], followRoads: Bool, travelMode: TravelMode, loopMode: LoopMode) {
        self.points = points
        // Older saves have no waits, or fewer than stops: a missing wait is no wait.
        self.waits = (0..<points.count).map { $0 < waits.count ? max(0, waits[$0]) : 0 }
        self.followRoads = followRoads
        self.travelMode = travelMode
        self.loopMode = loopMode
    }

    init(saved: SavedRoute) {
        self.init(points: saved.waypoints, waits: saved.waits ?? [], followRoads: saved.followRoads,
                  travelMode: saved.travelMode, loopMode: saved.loopMode)
    }

    /// The same route: same stops in the same order (to a hair), same waits, same options.
    func matches(_ other: RouteSnapshot) -> Bool {
        guard points.count == other.points.count,
              followRoads == other.followRoads, travelMode == other.travelMode, loopMode == other.loopMode
        else { return false }
        for i in points.indices {
            guard points[i].isClose(to: other.points[i], tolerance: 1e-9),
                  abs(waits[i] - other.waits[i]) < 0.5 else { return false }
        }
        return true
    }
}

enum RouteDraftGuard {
    /// A route has at least this many stops. One lone pin is not worth a question.
    static let minimumStops = 2

    /// True when throwing away the route being edited would lose work: it has stops and no
    /// saved copy matches it. (`savedCopy` is the library entry it was loaded from or last
    /// saved as, if that still exists.)
    static func hasUnsavedWork(editing: RouteSnapshot, savedCopy: RouteSnapshot?) -> Bool {
        guard editing.points.count >= minimumStops else { return false }
        guard let savedCopy else { return true }
        return !editing.matches(savedCopy)
    }
}
