import Foundation

/// How fast a traveller can take the route's curves: v = √(lateral acceleration
/// × radius).
///
/// A sharp turn (45° or more at one point) is a corner at a junction: its radius
/// is the circle through the points `span` metres before and after it (a car
/// cuts the corner, so a right angle drawn as a point is an 11 m arc). A gentle
/// bend is spread over the route's segments around it (radius = segment length ÷
/// angle), so a slight kink between two long straight segments, common in
/// simplified tracks, isn't mistaken for a tight corner.
public enum CurveSpeeds {
    /// Highest speed worth limiting (144 km/h); faster curves never hold anyone back.
    static let ceiling = 40.0
    /// A change of direction at least this sharp (radians) is a corner, not a bend.
    static let sharpTurn = Double.pi / 4
    /// The longest stretch a gentle bend is spread over, metres.
    static let longestBend = 100.0

    public static func limits(along path: RoutePath, profile: MotionProfile, span: Double = 16) -> [TripLimit] {
        guard let lateral = profile.lateralAcceleration, path.points.count >= 3, path.length > 2 * span else {
            return []
        }
        let points = path.points
        let n = points.count
        let closed = path.isClosed
        var limits: [TripLimit] = []

        func speed(at index: Int, distance s: Double, before: Int, after: Int) -> Double? {
            let incoming = Geo.bearing(from: points[before], to: points[index])
            let outgoing = Geo.bearing(from: points[index], to: points[after])
            let turn = abs(Geo.bearingDelta(from: incoming, to: outgoing)) * .pi / 180
            guard turn > 0.01 else { return nil }
            let radius: Double
            if turn >= sharpTurn {
                // Points `span` metres either side, wrapping round a closed loop.
                func around(_ d: Double) -> GeoPoint {
                    if closed { return path.sample(at: (d + path.length).truncatingRemainder(dividingBy: path.length)).point }
                    return path.sample(at: min(max(d, 0), path.length)).point
                }
                var arc = circumradius(around(s - span), points[index], around(s + span))
                // An exact U-turn (out and straight back): the points either side land on the
                // same spot, so no circle runs through them. The car still has to swing round,
                // in about the room `span` gives it.
                if !arc.isFinite { arc = span / 2 }
                radius = arc
            } else {
                let segments = min(Geo.distance(points[before], points[index]),
                                   Geo.distance(points[index], points[after]), longestBend)
                radius = segments / turn
            }
            guard radius.isFinite else { return nil }
            let v = max(profile.minimumTurnSpeed, (lateral * radius).squareRoot())
            return v < ceiling ? v : nil
        }

        /// The nearest point before/after `index` that isn't on top of it.
        func neighbour(of index: Int, step: Int) -> Int? {
            var j = index + step
            while j >= 0 && j < n {
                if Geo.distance(points[j], points[index]) > 0.5 { return j }
                j += step
            }
            return nil
        }

        // The points that aren't on top of the one before. A logger left running repeats
        // one spot thousands of times, and looking past all the repeats for each repeat's
        // neighbours is quadratic: the corners are found among these instead.
        var distinct = [0]
        for i in 1..<n where Geo.distance(points[i], points[distinct[distinct.count - 1]]) > 0.5 {
            distinct.append(i)
        }
        for k in distinct.indices.dropFirst().dropLast() {
            let i = distinct[k]
            guard let v = speed(at: i, distance: path.cumulative[i], before: distinct[k - 1],
                                after: distinct[k + 1]) else { continue }
            let s = path.cumulative[i]
            // Points of one bend: keep the slowest.
            if let last = limits.last, s - last.distance < 15 {
                if v < last.speed { limits[limits.count - 1] = TripLimit(distance: s, speed: v) }
            } else {
                limits.append(TripLimit(distance: s, speed: v))
            }
        }
        // A loop's corner where it closes: both where the lap ends and where it starts.
        if closed, let before = neighbour(of: n - 1, step: -1), let after = neighbour(of: 0, step: 1),
           let v = speed(at: 0, distance: 0, before: before, after: after) {
            limits.insert(TripLimit(distance: 0, speed: v), at: 0)
            limits.append(TripLimit(distance: path.length, speed: v))
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
