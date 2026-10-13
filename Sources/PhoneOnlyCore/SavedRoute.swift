import Foundation

/// A route kept on the iPhone: the stops and how it was set up to drive. The rules for keeping a list of
/// them (what is usable, what counts as the same route, how a damaged list loads) live here so they can be
/// tested; the iPhone app only stores the result.
public struct SavedRoute: Codable, Identifiable, Hashable, Sendable {
    public struct Stop: Codable, Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        /// Seconds to wait here.
        public var wait: Double

        public init(latitude: Double, longitude: Double, wait: Double = 0) {
            self.latitude = latitude
            self.longitude = longitude
            self.wait = wait
        }
    }

    public var id: UUID
    public var name: String
    public var stops: [Stop]
    public var driving: Bool
    public var followRoads: Bool
    public var speedKmh: Double
    /// "once", "loop" or "pingPong".
    public var repeats: String
    public var timeOfDayTraffic: Bool
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, stops: [Stop], driving: Bool, followRoads: Bool, speedKmh: Double,
                repeats: String, timeOfDayTraffic: Bool, savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.stops = stops
        self.driving = driving
        self.followRoads = followRoads
        self.speedKmh = speedKmh
        self.repeats = repeats
        self.timeOfDayTraffic = timeOfDayTraffic
        self.savedAt = savedAt
    }

    /// The most stops one route may have.
    public static let maxStops = 50

    /// Fit to use: two or more real places, sensible waits and a sensible speed.
    public var isUsable: Bool {
        stops.count >= 2 && stops.count <= Self.maxStops
            && stops.allSatisfy { Self.isPlace($0.latitude, $0.longitude) && $0.wait.isFinite && $0.wait >= 0 }
            && speedKmh.isFinite && speedKmh > 0 && speedKmh <= 400
            && ["once", "loop", "pingPong"].contains(repeats)
    }

    static func isPlace(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// As the crow flies, stop to stop (roads make it longer).
    public var straightLineMeters: Double {
        zip(stops, stops.dropFirst()).reduce(0) { total, pair in
            total + Self.distance(pair.0.latitude, pair.0.longitude, pair.1.latitude, pair.1.longitude)
        }
    }

    /// Great-circle distance in metres.
    public static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// The same stops in the same order (waits and settings aside).
    public func isSameRoute(as other: SavedRoute) -> Bool {
        guard stops.count == other.stops.count else { return false }
        return zip(stops, other.stops).allSatisfy {
            abs($0.latitude - $1.latitude) < 1e-5 && abs($0.longitude - $1.longitude) < 1e-5
        }
    }

    /// A name that is never empty or a wall of text.
    public static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Route" }
        return String(trimmed.prefix(60))
    }

    /// A stored list, with any entry that can't be read (or isn't a usable route) left out on its own: one
    /// damaged entry must not cost a person the rest.
    public static func decodeList(_ data: Data?) -> [SavedRoute] {
        guard let data, let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return items.compactMap { item in
            guard JSONSerialization.isValidJSONObject(item),
                  let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let route = try? JSONDecoder().decode(SavedRoute.self, from: itemData),
                  route.isUsable else { return nil }
            return route
        }
    }

    public static func encodeList(_ routes: [SavedRoute]) -> Data? {
        try? JSONEncoder().encode(routes)
    }
}
