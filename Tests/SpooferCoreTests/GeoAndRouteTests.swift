import XCTest
@testable import SpooferCore

final class GeoTests: XCTestCase {
    func testDistance() {
        let paris = GeoPoint(48.8566, 2.3522), london = GeoPoint(51.5074, -0.1278)
        XCTAssertEqual(Geo.distance(paris, london) / 1000, 343.5, accuracy: 1.0)
        XCTAssertEqual(Geo.distance(paris, paris), 0, accuracy: 1e-9)
        // One degree of longitude on the equator ≈ 111.2 km.
        XCTAssertEqual(Geo.distance(GeoPoint(0, 0), GeoPoint(0, 1)), 111_195, accuracy: 50)
    }

    func testBearing() {
        let o = GeoPoint(0, 0)
        XCTAssertEqual(Geo.bearing(from: o, to: GeoPoint(1, 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(Geo.bearing(from: o, to: GeoPoint(0, 1)), 90, accuracy: 1e-6)
        XCTAssertEqual(Geo.bearing(from: o, to: GeoPoint(-1, 0)), 180, accuracy: 1e-6)
        XCTAssertEqual(Geo.bearing(from: o, to: GeoPoint(0, -1)), 270, accuracy: 1e-6)
    }

    func testDestinationRoundTrip() {
        let start = GeoPoint(37.33, -122.0)
        let end = start.moved(by: 1000, bearing: 45)
        XCTAssertEqual(start.distance(to: end), 1000, accuracy: 0.5)
        XCTAssertEqual(start.bearing(to: end), 45, accuracy: 0.1)
        XCTAssertEqual(start.moved(by: 0, bearing: 123), start)
    }

    func testNormalisation() {
        XCTAssertEqual(Geo.normalizedLongitude(190), -170, accuracy: 1e-9)
        XCTAssertEqual(Geo.normalizedLongitude(-190), 170, accuracy: 1e-9)
        XCTAssertEqual(Geo.normalizedLongitude(45), 45)
        XCTAssertEqual(Geo.normalizedBearing(-90), 270, accuracy: 1e-9)
        XCTAssertEqual(Geo.normalizedBearing(725), 5, accuracy: 1e-9)
        XCTAssertEqual(Geo.bearingDelta(from: 350, to: 10), 20, accuracy: 1e-9)
        XCTAssertEqual(Geo.bearingDelta(from: 10, to: 350), -20, accuracy: 1e-9)
    }

    func testInterpolationTakesTheShortWayAcrossTheAntimeridian() {
        let mid = Geo.interpolate(GeoPoint(0, 179), GeoPoint(0, -179), fraction: 0.5)
        XCTAssertEqual(abs(mid.longitude), 180, accuracy: 1e-9)
    }

    func testCompassPoints() {
        XCTAssertEqual(Geo.compassPoint(0), "N")
        XCTAssertEqual(Geo.compassPoint(44), "NE")
        XCTAssertEqual(Geo.compassPoint(180), "S")
        XCTAssertEqual(Geo.compassPoint(359), "N")
    }
}

final class RoutePathTests: XCTestCase {
    /// ~1112 m per leg, due east along the equator.
    let line = [GeoPoint(0, 0), GeoPoint(0, 0.01), GeoPoint(0, 0.02)]

    func testSampling() {
        let path = RoutePath(line)
        XCTAssertEqual(path.length, 2 * Geo.distance(line[0], line[1]), accuracy: 1e-6)
        let mid = path.sample(at: path.length / 2)
        XCTAssertEqual(mid.point.longitude, 0.01, accuracy: 1e-9)
        XCTAssertEqual(mid.bearing, 90, accuracy: 1e-6)
        XCTAssertEqual(path.sample(at: -10).point, line[0])
        XCTAssertEqual(path.sample(at: 1e9).point.longitude, 0.02, accuracy: 1e-12)
        XCTAssertEqual(path.sample(at: path.length * 0.25).point.longitude, 0.005, accuracy: 1e-9)
    }

    func testClosedAndReversed() {
        let path = RoutePath(line)
        XCTAssertFalse(path.isClosed)
        let closed = path.closed()
        XCTAssertTrue(closed.isClosed)
        XCTAssertEqual(closed.points.count, 4)
        XCTAssertEqual(closed.closed().points.count, 4)   // idempotent
        XCTAssertEqual(path.reversed().start, line.last)
    }

    func testDegeneratePaths() {
        XCTAssertEqual(RoutePath([]).sample(at: 5).point, GeoPoint(0, 0))
        let single = RoutePath([GeoPoint(1, 2)])
        XCTAssertEqual(single.sample(at: 100).point, GeoPoint(1, 2))
        let still = RoutePlayback(path: RoutePath([GeoPoint(1, 2), GeoPoint(1, 2)]), loopMode: .once)
        XCTAssertTrue(still.isFinished)
    }

    func testPlaybackOnce() {
        var pb = RoutePlayback(path: RoutePath(line), loopMode: .once)
        let length = pb.path.length
        pb.advance(by: length / 2)
        XCTAssertEqual(pb.lapFraction, 0.5, accuracy: 1e-9)
        XCTAssertFalse(pb.isFinished)
        XCTAssertEqual(pb.remainingInLap, length / 2, accuracy: 1e-6)
        pb.advance(by: length)
        XCTAssertTrue(pb.isFinished)
        XCTAssertEqual(pb.travelled, length, accuracy: 1e-9)
        XCTAssertEqual(pb.current.point.longitude, 0.02, accuracy: 1e-12)
        XCTAssertEqual(pb.lap, 0)
    }

    func testPlaybackLoopClosesThePath() {
        var pb = RoutePlayback(path: RoutePath([GeoPoint(0, 0), GeoPoint(0, 0.01)]), loopMode: .loop)
        let leg = Geo.distance(GeoPoint(0, 0), GeoPoint(0, 0.01))
        XCTAssertEqual(pb.cycleLength, 2 * leg, accuracy: 1e-6)
        pb.advance(by: 2.5 * leg)            // one full lap + a quarter
        XCTAssertEqual(pb.lap, 1)
        XCTAssertFalse(pb.isFinished)
        XCTAssertEqual(pb.current.point.longitude, 0.005, accuracy: 1e-9)
        pb.advance(by: leg)                  // now heading back west
        XCTAssertEqual(pb.current.bearing, 270, accuracy: 1e-6)
    }

    func testPlaybackPingPongReverses() {
        var pb = RoutePlayback(path: RoutePath([GeoPoint(0, 0), GeoPoint(0, 0.01)]), loopMode: .pingPong)
        let leg = pb.path.length
        pb.advance(by: 1.5 * leg)
        XCTAssertEqual(pb.current.point.longitude, 0.005, accuracy: 1e-9)
        XCTAssertEqual(pb.current.bearing, 270, accuracy: 1e-6)
        pb.advance(by: leg)                  // 2.5 legs: back on the way out
        XCTAssertEqual(pb.lap, 1)
        XCTAssertEqual(pb.current.bearing, 90, accuracy: 1e-6)
    }

    func testSeek() {
        var pb = RoutePlayback(path: RoutePath(line), loopMode: .once)
        pb.seek(toLapFraction: 0.75)
        XCTAssertEqual(pb.current.point.longitude, 0.015, accuracy: 1e-9)
        pb.seek(toDistance: -5)
        XCTAssertEqual(pb.travelled, 0)
        let resumed = RoutePlayback(path: RoutePath(line), loopMode: .once, travelled: 1e9)
        XCTAssertTrue(resumed.isFinished)
    }
}

final class RouteBuilderTests: XCTestCase {
    let line = [GeoPoint(0, 0), GeoPoint(0, 0.01), GeoPoint(0, 0.02)]

    func testInterpolate() throws {
        let points = try RouteBuilder.interpolate(waypoints: line, duration: 60, sampleInterval: 0.5)
        XCTAssertEqual(points.count, 121)
        XCTAssertEqual(points.first?.offset, 0)
        XCTAssertEqual(points.last?.offset ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(points.last?.longitude ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.offset < $1.offset })
        XCTAssertThrowsError(try RouteBuilder.interpolate(waypoints: [line[0]], duration: 10))
        XCTAssertThrowsError(try RouteBuilder.interpolate(waypoints: line, duration: 0))
    }

    func testTimedTrackOnce() throws {
        let path = RoutePath(line)
        let track = try RouteBuilder.timedTrack(path: path, speed: 10, loopMode: .once)
        let expected = path.length / 10
        XCTAssertEqual(track.last?.offset ?? 0, expected, accuracy: 1e-6)
        XCTAssertEqual(track.last?.longitude ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(track.count, Int(expected.rounded(.up)) + 1)
    }

    func testTimedTrackLoopsAreUnrolled() throws {
        let path = RoutePath(line)
        let track = try RouteBuilder.timedTrack(path: path, speed: 50, loopMode: .loop, maxDuration: 1000)
        XCTAssertEqual(track.last?.offset ?? 0, 1000, accuracy: 1e-6)
        // It comes back past the start at least once.
        XCTAssertTrue(track.dropFirst(10).contains { abs($0.longitude) < 0.0005 })
        let capped = try RouteBuilder.timedTrack(path: path, speed: 50, loopMode: .pingPong,
                                                 maxDuration: 100_000, maxPoints: 500)
        XCTAssertLessThanOrEqual(capped.count, 502)
        XCTAssertThrowsError(try RouteBuilder.timedTrack(path: path, speed: 0, loopMode: .once))
    }

    func testGPXOutput() throws {
        let track = try RouteBuilder.timedTrack(path: RoutePath(line), speed: 100, loopMode: .once)
        let xml = RouteBuilder.gpx(track, name: "Tom & Jerry <test>")
        XCTAssertEqual(xml.components(separatedBy: "<trkpt").count - 1, track.count)
        XCTAssertTrue(xml.contains("Tom &amp; Jerry &lt;test&gt;"))
        XCTAssertTrue(xml.contains(".000Z") || xml.contains("Z</time>"))
        // And it parses back.
        let parsed = try RouteImporter.parse(Data(xml.utf8))
        XCTAssertEqual(parsed.points.count, track.count)
        XCTAssertEqual(parsed.duration ?? 0, track.last?.offset ?? 0, accuracy: 0.01)
    }
}

final class SimplifierTests: XCTestCase {
    func testStraightLineCollapses() {
        let points = (0...100).map { GeoPoint(0, Double($0) * 0.0001) }
        let simplified = RouteSimplifier.simplify(points, tolerance: 1)
        XCTAssertEqual(simplified, [points.first!, points.last!])
    }

    func testCornersSurvive() {
        let east = (0...50).map { GeoPoint(0, Double($0) * 0.0001) }
        let north = (1...50).map { GeoPoint(Double($0) * 0.0001, 0.005) }
        let simplified = RouteSimplifier.simplify(east + north, tolerance: 1)
        XCTAssertEqual(simplified.count, 3)
        XCTAssertEqual(simplified[1].latitude, 0, accuracy: 1e-12)
        XCTAssertEqual(simplified[1].longitude, 0.005, accuracy: 1e-12)
    }

    func testMaxPoints() {
        let zigzag = (0..<1000).map { GeoPoint(Double($0 % 2) * 0.001, Double($0) * 0.0002) }
        let simplified = RouteSimplifier.simplify(zigzag, maxPoints: 50)
        XCTAssertLessThanOrEqual(simplified.count, 50)
        XCTAssertEqual(simplified.first, zigzag.first)
        XCTAssertEqual(simplified.last, zigzag.last)
    }
}
