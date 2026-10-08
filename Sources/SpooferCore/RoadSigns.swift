import Foundation

/// Which signs and lights near a route are for traffic going the route's way,
/// worked out from the roads they're mapped on. OpenStreetMap puts a stop or
/// yield sign on its road just before the junction it's for, and tags lights and
/// signs that face one way with `traffic_signals:direction` or `direction`.
/// Without the roads (they're loaded for driving), everything near the route counts.
struct RoadSigns {
    enum Travel { case forward, backward }

    private let ways: [OSMWay]
    /// Node id → each road it's on, and where along it.
    private let placements: [Int64: [(way: Int, index: Int)]]
    /// Nodes where three or more road ends meet (driveways and car parks don't count).
    private let junctions: Set<Int64>

    init(ways: [OSMWay], signs: Set<Int64>) {
        var placements: [Int64: [(way: Int, index: Int)]] = [:]
        var degree: [Int64: Int] = [:]
        for (w, way) in ways.enumerated() where !way.nodeIDs.isEmpty && way.nodeIDs.count == way.points.count {
            let last = way.nodeIDs.count - 1
            for (i, id) in way.nodeIDs.enumerated() {
                if signs.contains(id) { placements[id, default: []].append((w, i)) }
                if way.tags["highway"] != "service" { degree[id, default: 0] += i == 0 || i == last ? 1 : 2 }
            }
        }
        self.ways = ways
        self.placements = placements
        junctions = Set(degree.filter { $0.value >= 3 }.keys)
    }

    /// Which ways along the route `node`, met `distance` metres along `path`,
    /// is for: going along the route, coming back the other way, or both. Nil
    /// when it's for neither: a side street's sign, say.
    func facing(of node: OSMNode, kind: RoadFeature.Kind, along path: RoutePath,
                at distance: Double) -> RoadFeature.Facing? {
        guard kind != .signalCrossing, let places = placements[node.id], !places.isEmpty else { return .both }
        let forward = applies(node, kind: kind, places: places,
                              heading: Self.heading(along: path, at: distance, back: false))
        let backward = applies(node, kind: kind, places: places,
                               heading: Self.heading(along: path, at: distance, back: true))
        switch (forward, backward) {
        case (true, true): return .both
        case (true, false): return .forward
        case (false, true): return .backward
        case (false, false): return nil
        }
    }

    private func applies(_ node: OSMNode, kind: RoadFeature.Kind, places: [(way: Int, index: Int)],
                         heading: Double) -> Bool {
        var onRoute = false
        for place in places {
            let way = ways[place.way]
            guard let travel = Self.travel(on: way, at: place.index, heading: heading) else { continue }
            onRoute = true
            if let faces = facing(of: node, kind: kind, on: way, at: place.index), faces != travel { continue }
            return true
        }
        // Only on roads the route crosses: a side street's sign. A light there
        // belongs to the same junction as the route's own.
        return !onRoute && kind == .trafficSignal
    }

    /// Which way along `way` the sign or light at `index` faces traffic; nil for both ways.
    private func facing(of node: OSMNode, kind: RoadFeature.Kind, on way: OSMWay, at index: Int) -> Travel? {
        let key = kind == .trafficSignal ? "traffic_signals:direction" : "direction"
        switch node.tags[key]?.lowercased() {
        case "forward": return .forward
        case "backward": return .backward
        default: break
        }
        // An untagged stop or yield sign is for traffic heading into the junction
        // just past it. One on the junction itself (an all-way stop) is for everyone.
        guard kind == .stopSign || kind == .giveWay, node.tags["stop"] != "all",
              !junctions.contains(node.id) else { return nil }
        switch (junctionDistance(on: way, from: index, step: 1), junctionDistance(on: way, from: index, step: -1)) {
        case let (ahead?, behind?): return abs(ahead - behind) < 5 ? nil : (ahead < behind ? .forward : .backward)
        case (_?, nil): return .forward
        case (nil, _?): return .backward
        case (nil, nil): return nil
        }
    }

    /// Metres along `way` from `index` to the nearest junction that way (`step`
    /// is +1 or −1), if there's one within 40 m.
    private func junctionDistance(on way: OSMWay, from index: Int, step: Int) -> Double? {
        var travelled = 0.0
        var i = index
        while i + step >= 0, i + step < way.points.count {
            travelled += Geo.distance(way.points[i], way.points[i + step])
            if travelled > 40 { return nil }
            i += step
            if junctions.contains(way.nodeIDs[i]) { return travelled }
        }
        return nil
    }

    /// Which way the route goes along `way` at `index`; nil when it isn't on that road there.
    static func travel(on way: OSMWay, at index: Int, heading: Double) -> Travel? {
        let p = way.points, n = p.count
        guard n >= 2, index >= 0, index < n else { return nil }
        let forward = index > 0 ? Geo.bearing(from: p[index - 1], to: p[index]) : Geo.bearing(from: p[0], to: p[1])
        let backward = index < n - 1 ? Geo.bearing(from: p[index + 1], to: p[index])
                                     : Geo.bearing(from: p[n - 1], to: p[n - 2])
        if abs(Geo.bearingDelta(from: heading, to: forward)) < 35 { return .forward }
        if abs(Geo.bearingDelta(from: heading, to: backward)) < 35 { return .backward }
        return nil
    }

    /// The route's heading over the 10 m before `distance`; for the way back,
    /// coming from the 10 m beyond it.
    static func heading(along path: RoutePath, at distance: Double, back: Bool) -> Double {
        let length = path.length
        let d = min(max(distance, 0), length)
        if back {
            let from = min(length, d + 10), to = max(0, min(d, from - 10))
            return Geo.bearing(from: path.sample(at: from).point, to: path.sample(at: to).point)
        }
        let from = max(0, d - 10), to = min(length, max(d, from + 10))
        return Geo.bearing(from: path.sample(at: from).point, to: path.sample(at: to).point)
    }
}
