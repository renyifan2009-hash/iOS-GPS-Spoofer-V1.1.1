import Foundation

/// Finds where points near a route are met along it, using a grid of the
/// route's segments so long routes stay fast.
public struct RouteMatcher: Sendable {
    public let path: RoutePath
    private let cell: Double
    private let grid: [Key: [Int]]

    private struct Key: Hashable, Sendable {
        let x: Int
        let y: Int
    }

    public init(path: RoutePath, cellSize: Double = 0.001) {
        self.path = path
        let cellSize = cellSize.isFinite && cellSize > 0 ? cellSize : 0.001
        cell = cellSize
        var grid: [Key: [Int]] = [:]
        let points = path.points
        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                // Walk the segment in half-cell steps: a long straight leg only
                // touches the cells it crosses.
                let a = points[i], b = points[i + 1]
                // A leg that ends at something that isn't a real place can't be put on a grid.
                guard a.isValid, b.isValid else { continue }
                let dLat = b.latitude - a.latitude
                // The short way round, so a leg over the antimeridian is a few cells, not the whole globe.
                let dLon = GridCells.longitudeDelta(from: a.longitude, to: b.longitude)
                let span = max(abs(dLat), abs(dLon))
                let steps = max(1, Int((span / (cellSize / 2)).rounded(.up)))
                var seen = Set<Key>()
                for k in 0...steps {
                    let t = Double(k) / Double(steps)
                    let key = Key(x: GridCells.column(of: a.longitude + dLon * t, cell: cellSize),
                                  y: GridCells.row(of: a.latitude + dLat * t, cell: cellSize))
                    if seen.insert(key).inserted { grid[key, default: []].append(i) }
                }
            }
        }
        self.grid = grid
    }

    /// Each pass of the route within `radius` metres of `point`: the distance
    /// along the route, and how far from it the point is.
    public func passes(near point: GeoPoint, radius: Double) -> [(distance: Double, offset: Double)] {
        let points = path.points
        guard points.count >= 2, point.isValid, radius.isFinite, radius >= 0 else { return [] }
        let latSpan = radius / 111_000 + cell
        let lonSpan = radius / (111_000 * max(0.05, cos(Geo.radians(point.latitude)))) + cell
        var candidates = Set<Int>()
        let columns = Int(floor((point.longitude - lonSpan) / cell))...Int(floor((point.longitude + lonSpan) / cell))
        let rows = Int(floor((point.latitude - latSpan) / cell))...Int(floor((point.latitude + latSpan) / cell))
        for column in columns {
            // Past +/-180 the next column is the one on the other side of the antimeridian.
            let x = GridCells.wrapped(column: column, cell: cell)
            for y in rows {
                candidates.formUnion(grid[Key(x: x, y: y)] ?? [])
            }
        }
        let k = Geo.earthRadius * .pi / 180
        let cosLat = cos(Geo.radians(point.latitude))
        func xy(_ p: GeoPoint) -> (x: Double, y: Double) {
            (Geo.normalizedLongitude(p.longitude - point.longitude) * k * cosLat, (p.latitude - point.latitude) * k)
        }
        var hits: [(distance: Double, offset: Double)] = []
        for i in candidates {
            let a = xy(points[i]), b = xy(points[i + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(a.x * dx + a.y * dy) / lengthSquared)) : 0
            let offset = hypot(a.x + t * dx, a.y + t * dy)
            guard offset <= radius else { continue }
            hits.append((path.cumulative[i] + t * (path.cumulative[i + 1] - path.cumulative[i]), offset))
        }
        hits.sort { $0.distance < $1.distance }
        // Neighbouring segments of one pass: keep the closest.
        var passes: [(distance: Double, offset: Double)] = []
        for hit in hits {
            if let last = passes.last, hit.distance - last.distance < 40 {
                if hit.offset < last.offset { passes[passes.count - 1] = hit }
            } else {
                passes.append(hit)
            }
        }
        return passes
    }

    /// How far along the route each waypoint is. The route runs through them in order.
    public func distances(ofWaypoints waypoints: [GeoPoint]) -> [Double] {
        var result: [Double] = []
        var from = 0
        for waypoint in waypoints {
            var found: Int?
            var i = from
            while i < path.points.count {
                if Geo.distance(path.points[i], waypoint) < 2 {
                    found = i
                    break
                }
                i += 1
            }
            if let found {
                result.append(path.cumulative[found])
                from = found
            } else {
                let previous = result.last ?? 0
                let pass = passes(near: waypoint, radius: 200).first { $0.distance >= previous - 1 }
                result.append(pass?.distance ?? previous)
            }
        }
        return result
    }
}

/// Cell numbers for the grids that find what is near a route. Longitude wraps
/// at the antimeridian, so a leg or a lookup that crosses it lands on the cells
/// on both sides of it instead of running round the world.
enum GridCells {
    /// The column holding `longitude`. 180 and -180 are one meridian, so both
    /// give the westernmost column.
    static func column(of longitude: Double, cell: Double) -> Int {
        var l = Geo.normalizedLongitude(longitude)
        if l >= 180 { l = -180 }
        return Int(floor(l / cell))
    }

    static func row(of latitude: Double, cell: Double) -> Int {
        Int(floor(latitude / cell))
    }

    /// The column that a number past the grid's edge (east of 180 or west of
    /// -180) stands for.
    static func wrapped(column: Int, cell: Double) -> Int {
        self.column(of: (Double(column) + 0.5) * cell, cell: cell)
    }

    /// `to - from` in degrees of longitude, the short way round.
    static func longitudeDelta(from: Double, to: Double) -> Double {
        var d = to - from
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }
}
