import Foundation
import XCTest
@testable import SpooferCore

final class RoadDataTests: XCTestCase {
    let a = GeoPoint(37, -122)

    func testPassesFindsEachPassAndItsDistance() {
        // Out 1 km north and back: a point 3 m east of the 400 m mark is passed twice.
        let top = a.moved(by: 1000, bearing: 0)
        let path = RoutePath([a, top, a])
        let matcher = RouteMatcher(path: path)
        let near = a.moved(by: 400, bearing: 0).moved(by: 3, bearing: 90)
        let passes = matcher.passes(near: near, radius: 10)
        XCTAssertEqual(passes.count, 2)
        XCTAssertEqual(passes.first?.distance ?? 0, 400, accuracy: 0.5)
        XCTAssertEqual(passes.last?.distance ?? 0, 1600, accuracy: 0.5)
        XCTAssertEqual(passes.first?.offset ?? 0, 3, accuracy: 0.2)
        XCTAssertTrue(matcher.passes(near: near.moved(by: 30, bearing: 90), radius: 10).isEmpty)
    }

    func testWaypointDistances() {
        let b = a.moved(by: 300, bearing: 0), c = b.moved(by: 500, bearing: 90)
        let path = RoutePath([a, a.moved(by: 150, bearing: 0), b, b.moved(by: 250, bearing: 90), c])
        XCTAssertEqual(RouteMatcher(path: path).distances(ofWaypoints: [a, b, c]).map { $0.rounded() }, [0, 300, 800])
    }

    func testMaxspeedParsing() {
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "50") ?? 0, 50 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "30 mph") ?? 0, 30 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "DE:urban") ?? 0, 50 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "GB:nsl_dual") ?? 0, 70 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "none") ?? 0, 130 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "50;30") ?? 0, 50 / 3.6, accuracy: 1e-9)
        XCTAssertNil(SpeedLimits.parse(maxspeed: "signals"))
        XCTAssertNil(SpeedLimits.parse(maxspeed: "fast"))
        XCTAssertEqual(SpeedLimits.speed(tags: ["highway": "residential"]) ?? 0, 40 / 3.6, accuracy: 1e-9)
        XCTAssertNil(SpeedLimits.speed(tags: ["highway": "footway"]))
    }

    func testZonesFollowTheRoadsUnderTheRoute() {
        let mid = a.moved(by: 500, bearing: 0), end = a.moved(by: 1000, bearing: 0)
        let path = RoutePath([a, end])
        let ways = [
            OSMWay(id: 1, points: [a, mid], tags: ["highway": "primary", "maxspeed": "45 mph"]),
            OSMWay(id: 2, points: [mid, end], tags: ["highway": "residential"]),
            // A cross street at 500 m must not win.
            OSMWay(id: 3, points: [mid.moved(by: 100, bearing: 270), mid.moved(by: 100, bearing: 90)],
                   tags: ["highway": "motorway"]),
        ]
        let zones = SpeedLimits.zones(along: path, ways: ways)
        XCTAssertEqual(zones.count, 2)
        XCTAssertEqual(zones.first?.speed ?? 0, 45 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(zones.last?.speed ?? 0, 40 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(zones.first?.end ?? 0, zones.last?.start ?? 1, accuracy: 1e-9)
        XCTAssertEqual(zones.last?.start ?? 0, 500, accuracy: 25)
    }

    // MARK: Overpass

    /// An Overpass answer for a 1 km route going north from `a`.
    private func answerJSON(path: RoutePath) -> Data {
        func at(_ d: Double, east: Double) -> GeoPoint { path.sample(at: d).point.moved(by: east, bearing: 90) }
        func node(_ id: Int, _ p: GeoPoint, _ tags: [String: String]) -> [String: Any] {
            ["type": "node", "id": id, "lat": p.latitude, "lon": p.longitude, "tags": tags]
        }
        func way(_ id: Int, _ points: [GeoPoint], _ tags: [String: String]) -> [String: Any] {
            ["type": "way", "id": id, "tags": tags,
             "geometry": points.map { ["lat": $0.latitude, "lon": $0.longitude] }]
        }
        let elements: [[String: Any]] = [
            node(1, at(200, east: 0), ["highway": "traffic_signals"]),
            node(2, at(215, east: 3), ["highway": "traffic_signals"]),             // same junction: merged
            node(3, at(500, east: 4), ["highway": "stop"]),
            node(4, at(700, east: 20), ["highway": "stop"]),                        // a side street's: ignored
            node(5, at(850, east: 2), ["highway": "crossing", "crossing": "traffic_signals"]),
            node(6, at(950, east: 0), ["highway": "traffic_signals", "traffic_signals": "emergency"]),
            way(10, [at(0, east: 0), at(600, east: 0)], ["highway": "primary", "maxspeed": "35 mph"]),
            way(11, [at(600, east: 0), at(1000, east: 0)], ["highway": "residential"]),
        ]
        return (try? JSONSerialization.data(withJSONObject: ["version": 0.6, "elements": elements])) ?? Data()
    }

    func testParseAndMatchAnOverpassAnswer() throws {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let answer = try OverpassLoader.parse(answerJSON(path: path))
        XCTAssertEqual(answer.nodes.count, 6)
        XCTAssertEqual(answer.ways.count, 2)
        let features = OverpassLoader.features(from: answer, along: path)
        XCTAssertEqual(features.features.filter { $0.kind == .trafficSignal }.map { $0.distance.rounded() }, [200])
        XCTAssertEqual(features.features.filter { $0.kind == .stopSign }.count, 1)
        XCTAssertEqual(features.features.filter { $0.kind == .signalCrossing }.count, 1)
        XCTAssertEqual(features.zones.first?.speed ?? 0, 35 * 0.44704, accuracy: 1e-9)
        XCTAssertGreaterThan(features.speedLimitCoverage(of: path.length), 0.9)
    }

    func testOverpassErrorRemarksThrow() {
        let data = Data(#"{"elements": [], "remark": "runtime error: Query timed out"}"#.utf8)
        XCTAssertThrowsError(try OverpassLoader.parse(data))
    }

    func testQueryLooksRight() {
        let line = [a, a.moved(by: 100, bearing: 0)]
        let q = OverpassLoader.query(for: line, padding: 3, roads: true)
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:25];"))
        XCTAssertTrue(q.contains("node(around:21,37.000000,-122.000000,"))
        XCTAssertTrue(q.contains("[highway=traffic_signals]"))
        XCTAssertTrue(q.contains("way(around:9,"))
        XCTAssertTrue(q.hasSuffix("out geom;"))
        XCTAssertFalse(OverpassLoader.query(for: line, padding: 3, roads: false).contains("way("))
    }

    func testLongRoutesAreSplitIntoPieces() {
        let path = RoutePath((0...40).map { a.moved(by: Double($0) * 1000, bearing: 0) })
        let chunks = OverpassLoader.chunks(of: path)
        XCTAssertEqual(chunks.count, 3)                      // 40 km in pieces of 15 km or less
        XCTAssertTrue(chunks.allSatisfy { $0.points.count <= 150 })
        XCTAssertEqual(chunks.first?.points.first, path.start)
        XCTAssertEqual(chunks.last?.points.last, path.end)
    }

    func testLoaderFallsBackThenUsesItsCache() async throws {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let body = answerJSON(path: path)
        let calls = Counter()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: cache) { request in
            let n = await calls.increment()
            let status = n == 1 ? 504 : 200        // the first server is busy
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (status == 200 ? body : Data(), response)
        }
        let first = try await loader.features(along: path, roads: true)
        XCTAssertEqual(first.uniqueCount(of: .trafficSignal), 1)
        XCTAssertTrue(first.complete)
        let before = await calls.value
        XCTAssertEqual(before, 2)
        _ = try await loader.features(along: path, roads: true)       // from the cache
        let after = await calls.value
        XCTAssertEqual(after, before)
    }
}

actor Counter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}
