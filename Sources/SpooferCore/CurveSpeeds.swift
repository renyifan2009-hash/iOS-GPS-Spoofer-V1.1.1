import Foundation

/// How fast a traveller can take the route's curves: v = √(lateral acceleration
/// × radius), with the radius of the circle through the points `span` metres
/// before and after each corner.
public enum CurveSpeeds {
    /// Highest speed worth limiting; faster curves never hold anyone back.
    static let ceiling = 45.0

    public static func limits(along path: RoutePath, profile: MotionProfile, span: Double = 12) -> [TripLimit] {
        guard let lateral = profile.lateralAcceleration, path.points.count >= 3, path.length > 2 * span else {
            return []
        }
        var limits: [TripLimit] = []
        for i in 1..<(path.points.count - 1) {
            let s = path.cumulative[i]
            guard s >= span, s <= path.length - span else { continue }
            let radius = circumradius(path.sample(at: s - span).point, path.points[i],
                                      path.sample(at: s + span).point)
            guard radius.isFinite else { continue }
            let speed = max(profile.minimumTurnSpeed, (lateral * radius).squareRoot())
            guard speed < ceiling else { continue }
            // Points of one bend: keep the slowest.
            if let last = limits.last, s - last.distance < 15 {
                if speed < last.speed { limits[limits.count - 1] = TripLimit(distance: s, speed: speed) }
            } else {
                limits.append(TripLimit(distance: s, speed: speed))
            }
        }
        return limits
    }

    /// Radius (metres) of the circle through three nearby points; infinity when they're in a line.
    public static func circumradius(_ a: GeoPoint, _ b: GeoPoint, _ c: GeoPoint) -> Double {
        let k = Geo.earthRadius * .pi / 180
        let cosLat = cos(Geo.radians(b.latitude))
        func xy(_ p: GeoPoint) -> (x: Double, y: Double) {
            (Geo.normalizedLongitude(p.longitude - b.longitude) * k * cosLat, (p.latitude - b.latitude) * k)
        }
        let p = xy(a), q = xy(c)   // b is the origin
        let twiceArea = abs(p.x * q.y - p.y * q.x)
        guard twiceArea > 1e-6 else { return .infinity }
        return hypot(p.x, p.y) * hypot(q.x, q.y) * hypot(q.x - p.x, q.y - p.y) / (2 * twiceArea)
    }
}
