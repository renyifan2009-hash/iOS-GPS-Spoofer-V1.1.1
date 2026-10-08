import Foundation

/// A point from OpenStreetMap with its tags.
public struct OSMNode: Sendable, Equatable {
    public var id: Int64
    public var point: GeoPoint
    public var tags: [String: String]

    public init(id: Int64, point: GeoPoint, tags: [String: String]) {
        self.id = id
        self.point = point
        self.tags = tags
    }
}

public struct OverpassAnswer: Sendable, Equatable {
    public var nodes: [OSMNode]
    public var ways: [OSMWay]
}

/// Loads traffic lights, stop and yield signs, signal crossings, speed bumps and
/// speed limits near a route from OpenStreetMap's public Overpass API: in pieces
/// of about 15 km, one request at a time, cached on disk for 30 days.
public struct OverpassLoader: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Public Overpass instances: the main one first, then others for when it's
    /// busy or unreachable (some networks and VPNs can't reach every one).
    public static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://maps.mail.ru/osm/tools/overpass/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]

    /// Seconds to wait for one server before trying the next.
    static let requestTimeout: TimeInterval = 25

    let userAgent: String
    let cacheDirectory: URL?
    let transport: Transport
    /// Which servers answered lately, so later lookups start with one that works.
    private let servers: ServerOrder

    public init(userAgent: String, cacheDirectory: URL?,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.userAgent = userAgent
        self.cacheDirectory = cacheDirectory
        self.transport = transport
        servers = ServerOrder(Self.endpoints)
    }

    /// The servers to try, best first: one that answered moves to the front,
    /// one that failed to the back.
    actor ServerOrder {
        private var order: [URL]

        init(_ order: [URL]) { self.order = order }

        var current: [URL] { order }

        func answered(_ url: URL) {
            order.removeAll { $0 == url }
            order.insert(url, at: 0)
        }

        func failed(_ url: URL) {
            guard order.count > 1, order.contains(url) else { return }
            order.removeAll { $0 == url }
            order.append(url)
        }
    }

    /// Search radii in metres around the route. Lights cover a whole junction;
    /// signs must be on the route's own road, not a side street.
    static let signalRadius = 18.0, signRadius = 6.0, crossingRadius = 12.0, roadRadius = 6.0

    /// Everything known along `path`. `roads` also loads the roads themselves
    /// (for driving): their speed limits, and which signs are for which direction.
    public func features(along path: RoutePath, roads: Bool,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> RoadFeatures {
        if let cacheDirectory { Self.pruneCache(cacheDirectory) }
        let chunks = Self.chunks(of: path)
        guard !chunks.isEmpty else { return .none }
        var nodes: [Int64: OSMNode] = [:]
        var ways: [Int64: OSMWay] = [:]
        var failures = 0
        var lastError: Error?
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            do {
                let answer = try await fetch(Self.query(for: chunk.points, padding: chunk.padding, roads: roads))
                for node in answer.nodes { nodes[node.id] = node }
                for way in answer.ways { ways[way.id] = way }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                lastError = error
            }
            progress?(Double(index + 1) / Double(chunks.count))
        }
        if failures == chunks.count, let lastError { throw lastError }
        var features = Self.features(from: OverpassAnswer(nodes: Array(nodes.values), ways: Array(ways.values)),
                                     along: path)
        features.complete = failures == 0
        return features
    }

    // MARK: Queries

    /// Pieces of at most 15 km, simplified to 150 points or fewer; `padding`
    /// widens the search by how far the simplified line may stray.
    static func chunks(of path: RoutePath) -> [(points: [GeoPoint], padding: Double)] {
        guard path.points.count >= 2 else { return [] }
        var chunks: [(points: [GeoPoint], padding: Double)] = []
        var start = 0
        while start < path.points.count - 1 {
            var end = start + 1
            while end < path.points.count - 1, path.cumulative[end] - path.cumulative[start] < 15_000 { end += 1 }
            let piece = Array(path.points[start...end])
            var tolerance = 2.0
            var simple = RouteSimplifier.simplify(piece, tolerance: tolerance)
            while simple.count > 150 && tolerance < 200 {
                tolerance *= 1.6
                simple = RouteSimplifier.simplify(piece, tolerance: tolerance)
            }
            chunks.append((simple, tolerance))
            start = end
        }
        return chunks
    }

    static func query(for points: [GeoPoint], padding: Double, roads: Bool) -> String {
        let line = points.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ",")
        func r(_ base: Double) -> Int { Int((base + padding).rounded(.up)) }
        var parts = [
            "node(around:\(r(signalRadius)),\(line))[highway=traffic_signals];",
            "node(around:\(r(signRadius)),\(line))[highway~\"^(stop|give_way)$\"];",
            "node(around:\(r(crossingRadius)),\(line))[highway=crossing][crossing=traffic_signals];",
            "node(around:\(r(signRadius)),\(line))[traffic_calming~\"^(bump|hump|table|cushion|yes)$\"];",
        ]
        if roads {
            parts.append("way(around:\(r(roadRadius)),\(line))"
                + "[highway~\"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|road)(_link)?$\"];")
        }
        return "[out:json][timeout:25];(" + parts.joined() + ");out geom;"
    }

    public static func parse(_ data: Data) throws -> OverpassAnswer {
        struct Element: Decodable {
            struct LatLon: Decodable {
                let lat: Double
                let lon: Double
            }
            let type: String
            let id: Int64
            let lat: Double?
            let lon: Double?
            let tags: [String: String]?
            let geometry: [LatLon?]?
            let nodes: [Int64]?
        }
        struct Answer: Decodable {
            let elements: [Element]
            let remark: String?
        }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        if let remark = answer.remark, remark.lowercased().contains("error") {
            throw SpoofError("OpenStreetMap couldn't answer: \(remark)")
        }
        var nodes: [OSMNode] = []
        var ways: [OSMWay] = []
        for element in answer.elements {
            switch element.type {
            case "node":
                guard let lat = element.lat, let lon = element.lon else { continue }
                nodes.append(OSMNode(id: element.id, point: GeoPoint(lat, lon), tags: element.tags ?? [:]))
            case "way":
                let geometry = element.geometry ?? []
                let refs = element.nodes ?? []
                var points: [GeoPoint] = []
                var ids: [Int64] = []
                for (i, entry) in geometry.enumerated() {
                    guard let entry else { continue }
                    points.append(GeoPoint(entry.lat, entry.lon))
                    if refs.count == geometry.count { ids.append(refs[i]) }
                }
                guard points.count >= 2 else { continue }
                ways.append(OSMWay(id: element.id, points: points, tags: element.tags ?? [:],
                                   nodeIDs: ids.count == points.count ? ids : []))
            default:
                continue
            }
        }
        return OverpassAnswer(nodes: nodes, ways: ways)
    }

    /// What a node is, how near the route it must be (metres), and for traffic
    /// calming the speed over it.
    static func classify(_ node: OSMNode) -> (kind: RoadFeature.Kind, radius: Double, speed: Double?)? {
        switch node.tags["highway"] {
        case "traffic_signals":
            // Lights only for emergency vehicles, flashing ones and ramp meters don't stop traffic.
            if ["emergency", "blinker", "ramp_meter"].contains(node.tags["traffic_signals"] ?? "") { return nil }
            return (.trafficSignal, signalRadius, nil)
        case "stop":
            return (.stopSign, signRadius, nil)
        case "give_way":
            return (.giveWay, signRadius, nil)
        case "crossing" where node.tags["crossing"] == "traffic_signals":
            return (.signalCrossing, crossingRadius, nil)
        default:
            guard let value = node.tags["traffic_calming"], let speed = TripOdds.calmingSpeed(value) else { return nil }
            return (.trafficCalming, signRadius, speed)
        }
    }

    /// Places an answer's nodes along `path` and turns its roads into speed zones.
    public static func features(from answer: OverpassAnswer, along path: RoutePath) -> RoadFeatures {
        let matcher = RouteMatcher(path: path)
        let signs = RoadSigns(ways: answer.ways, signs: Set(answer.nodes.map(\.id)))
        var features: [RoadFeature] = []
        for node in answer.nodes.sorted(by: { $0.id < $1.id }) {
            guard let (kind, radius, speed) = classify(node) else { continue }
            var passes = matcher.passes(near: node.point, radius: radius)
            // A closed loop starts and ends at the same place: something near it
            // is met once, as the lap ends.
            if path.isClosed, passes.count >= 2, let first = passes.first, let last = passes.last,
               first.distance < 40, last.distance > path.length - 40 {
                passes.removeFirst()
            }
            for pass in passes {
                // Only signs for the route's direction (out and back: either).
                guard let facing = signs.facing(of: node, kind: kind, along: path, at: pass.distance) else { continue }
                features.append(RoadFeature(kind: kind, distance: pass.distance, point: node.point,
                                            facing: facing, speed: speed))
            }
        }
        var kept = firstOfEachJunction(features)
        // A crossing light at a junction with traffic lights is part of that
        // junction's lights: only mid-block crossing lights stand on their own.
        let lights = kept.filter { $0.kind == .trafficSignal }.map(\.distance)
        kept.removeAll { feature in
            feature.kind == .signalCrossing && lights.contains { abs($0 - feature.distance) < 40 }
        }
        return RoadFeatures(features: kept, zones: SpeedLimits.zones(along: path, ways: answer.ways))
    }

    /// A junction often has a light on each approach: one stop per 30 m (signs
    /// and bumps: 15 m), the first one met. Going along the route and coming
    /// back, the first one met can differ, so each direction picks its own.
    static func firstOfEachJunction(_ features: [RoadFeature]) -> [RoadFeature] {
        let sorted = features.sorted { $0.distance < $1.distance }
        func firsts(in order: [Int], facing: RoadFeature.Facing) -> Set<Int> {
            var kept = Set<Int>()
            var last: [RoadFeature.Kind: Double] = [:]
            for i in order where sorted[i].facing.overlaps(facing) {
                let feature = sorted[i]
                let gap: Double = feature.kind == .trafficSignal || feature.kind == .signalCrossing ? 30 : 15
                if let previous = last[feature.kind], abs(feature.distance - previous) < gap { continue }
                last[feature.kind] = feature.distance
                kept.insert(i)
            }
            return kept
        }
        let forward = firsts(in: Array(sorted.indices), facing: .forward)
        let backward = firsts(in: sorted.indices.reversed(), facing: .backward)
        return sorted.indices.compactMap { i in
            var feature = sorted[i]
            switch (forward.contains(i), backward.contains(i)) {
            case (true, true): feature.facing = .both
            case (true, false): feature.facing = .forward
            case (false, true): feature.facing = .backward
            case (false, false): return nil
            }
            return feature
        }
    }

    // MARK: Fetching

    private func fetch(_ query: String) async throws -> OverpassAnswer {
        let cacheFile = cacheDirectory?.appendingPathComponent(Self.cacheName(for: query))
        if let cacheFile, let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 30 * 86_400,
           let data = try? Data(contentsOf: cacheFile), let answer = try? Self.parse(data) {
            return answer
        }
        var lastError: Error = SpoofError("couldn't reach OpenStreetMap")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        for (index, endpoint) in await servers.current.enumerated() {
            if index > 0 { try await Task.sleep(for: .seconds(1)) }
            var request = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
            request.httpMethod = "POST"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("data=\(encoded)".utf8)
            attempts: for attempt in 0..<2 {
                do {
                    let (data, response) = try await transport(request)
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    if status == 200 {
                        let answer = try Self.parse(data)
                        await servers.answered(endpoint)
                        if let cacheFile {
                            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                                     withIntermediateDirectories: true)
                            try? data.write(to: cacheFile)
                        }
                        return answer
                    }
                    lastError = SpoofError("OpenStreetMap answered \(status)")
                    // Out of turns (429): leave this server alone for now; it asks for 30 s.
                    // Busy (503, 504): wait a moment and ask it once more.
                    guard attempt == 0, [503, 504].contains(status) else { break attempts }
                    let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 3
                    try await Task.sleep(for: .seconds(min(10, max(1, wait))))
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch {
                    // Unreachable, timed out, or an answer it couldn't read: the next server.
                    lastError = error
                    break attempts
                }
            }
            await servers.failed(endpoint)
        }
        throw lastError
    }

    /// Answers older than 30 days are no use (they're refetched): remove them.
    static func pruneCache(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "json" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > 30 * 86_400 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// FNV-1a: a stable file name for a query.
    static func cacheName(for query: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in query.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01B3 }
        return String(format: "%016llx.json", hash)
    }
}
