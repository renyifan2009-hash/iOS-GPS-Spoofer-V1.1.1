import XCTest
@testable import SpooferCore

/// What the route and road code does with positions that are not real places,
/// and with routes that cross the antimeridian.
final class BadPositionTests: XCTestCase {
    func testAPathHoldsOnlyRealPlaces() {
        // Used to be a phantom 40,000 km route, and then to stop the app: Int(floor(NaN)).
        let a = GeoPoint(37, -122)
        let b = a.moved(by: 400, bearing: 0)
        let path = RoutePath([a, GeoPoint(.nan, 0), b, GeoPoint(95, 0), GeoPoint(0, .infinity)])
        XCTAssertEqual(path.points, [a, b])
        XCTAssertEqual(path.length, 400, accuracy: 0.5)
        XCTAssertEqual(path.sample(at: 200).point.latitude, a.moved(by: 200, bearing: 0).latitude, accuracy: 1e-6)
        XCTAssertEqual(RoutePath([GeoPoint(.nan, .nan)]).points, [])
        // A path of real places is kept as it is.
        XCTAssertEqual(RoutePath([a, b]).points, [a, b])
    }

    func testRouteMatcherIgnoresAnythingItCannotPlace() {
        let a = GeoPoint(37, -122)
        let matcher = RouteMatcher(path: RoutePath([a, GeoPoint(.nan, 0), a.moved(by: 400, bearing: 0)]))
        XCTAssertEqual(matcher.passes(near: a.moved(by: 200, bearing: 0), radius: 20).count, 1)
        XCTAssertTrue(matcher.passes(near: GeoPoint(.nan, 0), radius: 100).isEmpty)
        XCTAssertTrue(matcher.passes(near: a, radius: .nan).isEmpty)
        XCTAssertTrue(matcher.passes(near: a, radius: -5).isEmpty)
        XCTAssertEqual(matcher.distances(ofWaypoints: [a, a.moved(by: 400, bearing: 0)]).map { $0.rounded() }, [0, 400])
        // A cell size that cannot work falls back to the default.
        for size in [0, -1, Double.nan, .infinity] {
            let m = RouteMatcher(path: RoutePath([a, a.moved(by: 400, bearing: 0)]), cellSize: size)
            XCTAssertEqual(m.passes(near: a.moved(by: 100, bearing: 0), radius: 20).count, 1)
        }
    }

    func testSpeedZonesSkipBadWays() {
        let a = GeoPoint(37, -122)
        let route = RoutePath([a, a.moved(by: 400, bearing: 0)])
        let ways = [
            OSMWay(id: 1, points: [a, GeoPoint(.nan, -122), a.moved(by: 400, bearing: 0)], tags: ["highway": "primary"]),
            OSMWay(id: 2, points: [a, GeoPoint(37.001, 400)], tags: ["highway": "primary"]),
            OSMWay(id: 3, points: [a, a.moved(by: 400, bearing: 0)], tags: ["highway": "residential"]),
        ]
        let zones = SpeedLimits.zones(along: route, ways: ways)
        XCTAssertEqual(zones.count, 1)
        XCTAssertEqual(zones.first?.speed ?? 0, 40 / 3.6, accuracy: 1e-9)
        // A spacing that cannot work gives no zones rather than stopping the app.
        for spacing in [0, -20, Double.nan, .infinity] {
            XCTAssertTrue(SpeedLimits.zones(along: route, ways: ways, spacing: spacing).isEmpty)
        }
    }

    func testSimplifierIgnoresBadPoints() {
        let clean = (0..<300).map { GeoPoint(Double($0) * 0.0002, sin(Double($0) / 9) * 0.002) }
        var dirty = clean
        dirty.insert(GeoPoint(.nan, 0), at: 100)
        dirty.insert(GeoPoint(0, .infinity), at: 200)
        XCTAssertEqual(RouteSimplifier.simplify(dirty, tolerance: 2), RouteSimplifier.simplify(clean, tolerance: 2))
        XCTAssertEqual(RouteSimplifier.simplify(dirty, maxPoints: 40), RouteSimplifier.simplify(clean, maxPoints: 40))
    }

    func testRoadDataQueriesNeverCarryABadPosition() async throws {
        let queries = Counter()
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil) { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            XCTAssertFalse(body.lowercased().contains("nan"), body)
            _ = await queries.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"elements": []}"#.utf8), response)
        }
        let a = GeoPoint(37, -122)
        let path = RoutePath([a, GeoPoint(.nan, -122), a.moved(by: 3000, bearing: 0)])
        let features = try await loader.features(along: path, roads: true)
        XCTAssertTrue(features.complete)
        let asked = await queries.value
        XCTAssertEqual(asked, 1)       // one piece, not one request per leg
    }
}

/// A route across the 180th meridian: a leg from 179.99 to -179.99 is 2 km, not
/// a walk round the world, and things beside it on either side are found.
final class AntimeridianTests: XCTestCase {
    private let east = GeoPoint(0, 179.99)
    private let west = GeoPoint(0, -179.99)

    func testRouteMatcherFindsThingsOnBothSidesOf180() {
        for (from, to) in [(east, west), (west, east)] {
            let matcher = RouteMatcher(path: RoutePath([from, to]))
            XCTAssertEqual(RoutePath([from, to]).length, 2224, accuracy: 5)
            for lon in [179.9999, -179.9999, 180, -180, 179.995, -179.995] {
                let passes = matcher.passes(near: GeoPoint(0, lon), radius: 20)
                XCTAssertEqual(passes.count, 1, "longitude \(lon) \(from.longitude) -> \(to.longitude)")
            }
            XCTAssertTrue(matcher.passes(near: GeoPoint(0, 179.9), radius: 20).isEmpty)
            XCTAssertTrue(matcher.passes(near: GeoPoint(0.01, 180), radius: 20).isEmpty)
        }
    }

    func testDistancesAlongTheRouteAreRight() {
        let path = RoutePath([east, GeoPoint(0, 180), west, GeoPoint(0.01, -179.98)])
        let matcher = RouteMatcher(path: path)
        let hit = matcher.passes(near: GeoPoint(0, -179.995), radius: 20)
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit.first?.distance ?? 0, Geo.distance(east, GeoPoint(0, -179.995)), accuracy: 1)
        XCTAssertEqual(matcher.distances(ofWaypoints: [east, west]).map { $0.rounded() },
                       [0, (Geo.distance(east, west)).rounded()])
    }

    func testSignsNearTheMeridianAreMet() {
        let path = RoutePath([east, west])
        let light = OSMNode(id: 1, point: GeoPoint(0.00005, 179.9995), tags: ["highway": "traffic_signals"])
        let stop = OSMNode(id: 2, point: GeoPoint(0.00005, -179.9995), tags: ["highway": "stop"])
        let features = OverpassLoader.features(from: OverpassAnswer(nodes: [light, stop], ways: []), along: path)
        XCTAssertEqual(features.features.map(\.kind), [.trafficSignal, .stopSign])
        XCTAssertEqual(features.features[0].distance, Geo.distance(east, GeoPoint(0, 179.9995)), accuracy: 6)
        XCTAssertEqual(features.features[1].distance, Geo.distance(east, GeoPoint(0, -179.9995)), accuracy: 6)
    }

    func testSpeedZonesAcrossTheMeridian() {
        let path = RoutePath([east, west])
        let ways = [
            OSMWay(id: 1, points: [east, GeoPoint(0, 180)], tags: ["highway": "primary", "maxspeed": "50"]),
            OSMWay(id: 2, points: [GeoPoint(0, -180), west], tags: ["highway": "residential", "maxspeed": "30"]),
            // One road that itself crosses it.
            OSMWay(id: 3, points: [east, west], tags: ["highway": "tertiary", "maxspeed": "50"]),
        ]
        let zones = SpeedLimits.zones(along: path, ways: ways)
        XCTAssertFalse(zones.isEmpty)
        XCTAssertEqual(zones.first?.start ?? 1, 0, accuracy: 1e-6)
        XCTAssertEqual(zones.last?.end ?? 0, path.length, accuracy: 25)
        XCTAssertTrue(zones.allSatisfy { $0.speed > 0 })
    }
}
