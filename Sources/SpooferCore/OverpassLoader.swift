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

/// Loads traffic lights, stop and yield signs, signal crossings and speed
/// limits near a route from OpenStreetMap's public Overpass API: in pieces of
/// about 15 km, one request at a time, cached on disk for 30 days.
public struct OverpassLoader: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The main public instance first; another public instance if it's busy.
    public static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]

    let userAgent: String
    let cacheDirectory: URL?
    let transport: Transport

    public init(userAgent: String, cacheDirectory: URL?,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.userAgent = userAgent
        self.cacheDirectory = cacheDirectory
        self.transport = transport
    }

    /// Search radii in metres around the route. Lights cover a whole junction;
    /// signs must be on the route's own road, not a side street.
    static let signalRadius = 18.0, signRadius = 6.0, crossingRadius = 12.0, roadRadius = 6.0

    /// Everything known along `path`. `roads` also loads speed limits (for driving).
    public func features(along path: RoutePath, roads: Bool,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> RoadFeatures {
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
                let points = (element.geometry ?? []).compactMap { $0.map { GeoPoint($0.lat, $0.lon) } }
                guard points.count >= 2 else { continue }
                ways.append(OSMWay(id: element.id, points: points, tags: element.tags ?? [:]))
            default:
                continue
            }
        }
        return OverpassAnswer(nodes: nodes, ways: ways)
    }

    /// Places an answer's nodes along `path` and turns its roads into speed zones.
    public static func features(from answer: OverpassAnswer, along path: RoutePath) -> RoadFeatures {
        let matcher = RouteMatcher(path: path)
        var features: [RoadFeature] = []
        for node in answer.nodes.sorted(by: { $0.id < $1.id }) {
            let kind: RoadFeature.Kind
            let radius: Double
            switch node.tags["highway"] {
            case "traffic_signals":
                // Lights only for emergency vehicles, flashing ones and ramp meters don't stop traffic.
                if ["emergency", "blinker", "ramp_meter"].contains(node.tags["traffic_signals"] ?? "") { continue }
                (kind, radius) = (.trafficSignal, signalRadius)
            case "stop":
                (kind, radius) = (.stopSign, signRadius)
            case "give_way":
                (kind, radius) = (.giveWay, signRadius)
            case "crossing":
                (kind, radius) = (.signalCrossing, crossingRadius)
            default:
                continue
            }
            for pass in matcher.passes(near: node.point, radius: radius) {
                features.append(RoadFeature(kind: kind, distance: pass.distance, point: node.point))
            }
        }
        // A junction often has a light on each approach: one stop per 30 m (signs: 15 m).
        features.sort { $0.distance < $1.distance }
        var kept: [RoadFeature] = []
        for feature in features {
            let gap: Double = feature.kind == .trafficSignal || feature.kind == .signalCrossing ? 30 : 15
            if let previous = kept.last(where: { $0.kind == feature.kind }), feature.distance - previous.distance < gap {
                continue
            }
            kept.append(feature)
        }
        return RoadFeatures(features: kept, zones: SpeedLimits.zones(along: path, ways: answer.ways))
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
        for (index, endpoint) in Self.endpoints.enumerated() {
            if index > 0 { try await Task.sleep(for: .seconds(1)) }
            var request = URLRequest(url: endpoint, timeoutInterval: 40)
            request.httpMethod = "POST"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
            request.httpBody = Data("data=\(encoded)".utf8)
            do {
                let (data, response) = try await transport(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    lastError = SpoofError("OpenStreetMap answered \(status)")
                    continue
                }
                let answer = try Self.parse(data)
                if let cacheFile {
                    try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? data.write(to: cacheFile)
                }
                return answer
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// FNV-1a: a stable file name for a query.
    static func cacheName(for query: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in query.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01B3 }
        return String(format: "%016llx.json", hash)
    }
}
