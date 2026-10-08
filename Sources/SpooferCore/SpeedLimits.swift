import Foundation

/// A road from OpenStreetMap: its shape and tags.
public struct OSMWay: Sendable, Equatable {
    public var id: Int64
    public var points: [GeoPoint]
    public var tags: [String: String]
    /// The id of the node at each point (empty when not known).
    public var nodeIDs: [Int64]

    public init(id: Int64, points: [GeoPoint], tags: [String: String], nodeIDs: [Int64] = []) {
        self.id = id
        self.points = points
        self.tags = tags
        self.nodeIDs = nodeIDs
    }
}

/// Road speed limits from OpenStreetMap tags.
public enum SpeedLimits {
    static let kmh = 1 / 3.6
    static let mph = 0.44704

    /// Usual limits by road type, km/h, when a road has no `maxspeed`.
    static let defaults: [String: Double] = [
        "motorway": 110, "motorway_link": 60, "trunk": 90, "trunk_link": 50,
        "primary": 70, "primary_link": 50, "secondary": 60, "secondary_link": 40,
        "tertiary": 50, "tertiary_link": 40, "unclassified": 50, "residential": 40,
        "living_street": 15, "service": 20, "road": 50,
    ]

    /// Zone codes (`DE:urban`, `GB:nsl_dual`…), m/s.
    static let zoneCodes: [String: Double] = [
        "urban": 50 * kmh, "rural": 90 * kmh, "motorway": 120 * kmh, "trunk": 100 * kmh,
        "living_street": 20 * kmh, "bicycle_road": 30 * kmh, "school": 30 * kmh,
        "nsl_single": 60 * mph, "nsl_dual": 70 * mph, "nsl_restricted": 30 * mph,
    ]

    /// `maxspeed` in m/s: "50", "30 mph", "DE:urban", "none"; nil for
    /// "signals", "variable" and anything it can't read.
    public static func parse(maxspeed raw: String) -> Double? {
        let value = (raw.split(separator: ";").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "none": return 130 * kmh
        case "walk": return 7 * kmh
        case "", "signals", "variable", "unknown": return nil
        default: break
        }
        if let colon = value.firstIndex(of: ":") {
            let code = String(value[value.index(after: colon)...])
            if let speed = zoneCodes[code] { return speed }
            if code.hasPrefix("zone"), let number = Double(code.dropFirst(4)) { return number * kmh }
            return nil
        }
        let parts = value.split(separator: " ")
        guard let number = parts.first.flatMap({ Double($0) }), number > 0, number < 300 else { return nil }
        if parts.count > 1, parts[1].hasPrefix("mph") { return number * mph }
        if parts.count > 1, parts[1].hasPrefix("knots") { return number * 0.514444 }
        return number * kmh
    }

    /// A road's limit in m/s, or nil if it isn't a road for cars.
    public static func speed(tags: [String: String]) -> Double? {
        guard let highway = tags["highway"], let fallback = defaults[highway] else { return nil }
        return tags["maxspeed"].flatMap(parse(maxspeed:)) ?? fallback * kmh
    }

    /// Speed zones along `path`: every `spacing` metres, the limit of the road
    /// under the route (running the same way, either direction), merged into stretches.
    public static func zones(along path: RoutePath, ways: [OSMWay], spacing: Double = 20) -> [SpeedZone] {
        guard path.length > 0, !ways.isEmpty else { return [] }
        var segments: [(a: GeoPoint, b: GeoPoint, speed: Double)] = []
        for way in ways {
            guard let speed = speed(tags: way.tags), way.points.count >= 2 else { continue }
            for i in 0..<(way.points.count - 1) { segments.append((way.points[i], way.points[i + 1], speed)) }
        }
        guard !segments.isEmpty else { return [] }

        let cell = 0.0005
        func key(_ x: Int, _ y: Int) -> Int64 {
            Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))
        }
        var grid: [Int64: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            let span = max(abs(segment.b.latitude - segment.a.latitude), abs(segment.b.longitude - segment.a.longitude))
            let steps = max(1, Int((span / (cell / 2)).rounded(.up)))
            for k in 0...steps {
                let t = Double(k) / Double(steps)
                let lon = segment.a.longitude + (segment.b.longitude - segment.a.longitude) * t
                let lat = segment.a.latitude + (segment.b.latitude - segment.a.latitude) * t
                let id = key(Int(floor(lon / cell)), Int(floor(lat / cell)))
                if grid[id]?.last != index { grid[id, default: []].append(index) }
            }
        }

        let count = Int(path.length / spacing) + 1
        var speeds = [Double?](repeating: nil, count: count)
        let k = Geo.earthRadius * .pi / 180
        for n in 0..<count {
            let sample = path.sample(at: min(path.length, Double(n) * spacing))
            let p = sample.point
            let cosLat = cos(Geo.radians(p.latitude))
            func xy(_ q: GeoPoint) -> (x: Double, y: Double) {
                (Geo.normalizedLongitude(q.longitude - p.longitude) * k * cosLat, (q.latitude - p.latitude) * k)
            }
            var candidates = Set<Int>()
            let x = Int(floor(p.longitude / cell)), y = Int(floor(p.latitude / cell))
            for dx in -1...1 {
                for dy in -1...1 { candidates.formUnion(grid[key(x + dx, y + dy)] ?? []) }
            }
            var best: (offset: Double, speed: Double)?
            for index in candidates.sorted() {
                let segment = segments[index]
                let turn = abs(Geo.bearingDelta(from: sample.bearing, to: Geo.bearing(from: segment.a, to: segment.b)))
                guard turn < 35 || turn > 145 else { continue }   // the same road, not a cross street
                let a = xy(segment.a), b = xy(segment.b)
                let ex = b.x - a.x, ey = b.y - a.y
                let lengthSquared = ex * ex + ey * ey
                let t = lengthSquared > 0 ? max(0, min(1, -(a.x * ex + a.y * ey) / lengthSquared)) : 0
                let offset = hypot(a.x + t * ex, a.y + t * ey)
                guard offset <= 12 else { continue }
                if best == nil || offset < best!.offset { best = (offset, segment.speed) }
            }
            speeds[n] = best?.speed
        }

        // Short gaps (junctions, small mapping gaps) keep the speed before them.
        var last: Double?
        var gap = 0
        for n in 0..<count {
            if let speed = speeds[n] {
                last = speed
                gap = 0
            } else if let last, gap < 10 {
                speeds[n] = last
                gap += 1
            }
        }
        var zones: [SpeedZone] = []
        for n in 0..<count {
            guard let speed = speeds[n] else { continue }
            let start = Double(n) * spacing, end = min(path.length, start + spacing)
            guard end > start else { continue }
            if let previous = zones.last, previous.speed == speed, abs(previous.end - start) < 1e-6 {
                zones[zones.count - 1].end = end
            } else {
                zones.append(SpeedZone(start: start, end: end, speed: speed))
            }
        }
        // Slivers shorter than 60 m join the zone before them.
        var merged: [SpeedZone] = []
        for zone in zones {
            if zone.end - zone.start < 60, let previous = merged.last, abs(previous.end - zone.start) < 1e-6 {
                merged[merged.count - 1].end = zone.end
            } else {
                merged.append(zone)
            }
        }
        return merged
    }
}
