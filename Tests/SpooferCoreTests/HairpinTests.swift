import XCTest
@testable import SpooferCore

/// Turning right round: out and straight back.
final class HairpinTests: XCTestCase {
    private let a = GeoPoint(37, -122)

    // MARK: Turning right round

    func testExactReversalIsSlowedLikeAnyOtherSharpTurn() throws {
        // Out to B and straight back the same way: the car has to swing round at B.
        let b = a.moved(by: 300, bearing: 0)
        let limits = CurveSpeeds.limits(along: RoutePath([a, b, a]), profile: .drive)
        let atB = try XCTUnwrap(limits.first { abs($0.distance - 300) < 1 })
        // A U-turn in the room the corner formula allows: sqrt(2.0 m/s² × 8 m).
        XCTAssertEqual(atB.speed, 4.0, accuracy: 0.05)
        XCTAssertTrue(limits.allSatisfy { $0.speed <= 5 })
        // Walkers don't slow for corners at all.
        XCTAssertTrue(CurveSpeeds.limits(along: RoutePath([a, b, a]), profile: .walk).isEmpty)
    }

    func testNearlyAReversalGivesTheSameLimitAsAnExactOne() throws {
        let b = a.moved(by: 300, bearing: 0)
        let exact = CurveSpeeds.limits(along: RoutePath([a, b, a]), profile: .drive)
        let offset = CurveSpeeds.limits(along: RoutePath([a, b, a.moved(by: 3, bearing: 90)]), profile: .drive)
        let exactSpeed = try XCTUnwrap(exact.first { abs($0.distance - 300) < 1 }).speed
        let offsetSpeed = try XCTUnwrap(offset.first { abs($0.distance - 300) < 1 }).speed
        XCTAssertEqual(exactSpeed, offsetSpeed, accuracy: 0.6)
    }

    func testATwoWaypointLoopDoesNotFlipItsHeadingAtFullSpeed() {
        // Two points with Loop: the played path is A, B, A. The car used to reach B at
        // cruise speed and turn round in one tick.
        let b = a.moved(by: 400, bearing: 0)
        let planner = TripPlanner(path: RoutePlayback(path: RoutePath([a, b]), loopMode: .loop).path,
                                  loopMode: .loop, settings: TripSettings(topSpeed: 20))
        var playback = RoutePlayback(path: planner.path, loopMode: .loop)
        var trip = TripController(planner: planner, seed: 3)
        var fastestNearTheTurn = 0.0
        var previousBearing = playback.current.bearing
        var worstSnap = 0.0
        var time = 0.0
        while time < 200 {
            playback.advance(by: trip.step(dt: 0.25, lapDistance: playback.lapDistance, lap: playback.lap))
            time += 0.25
            let bearing = playback.current.bearing
            let snap = abs(Geo.bearingDelta(from: previousBearing, to: bearing))
            if snap > 90 { worstSnap = max(worstSnap, trip.speed) }
            previousBearing = bearing
            let toTurn = min(abs(playback.lapDistance - 400), abs(playback.lapDistance - 800), playback.lapDistance)
            if toTurn < 1.5 { fastestNearTheTurn = max(fastestNearTheTurn, trip.speed) }
        }
        XCTAssertGreaterThan(playback.lap, 0, "it should have gone round at least once")
        // Braking at 2.7 m/s² into a 4 m/s turn: within a metre or two of it, still about 4.
        XCTAssertLessThan(fastestNearTheTurn, 5.5, "speed at a U-turn, m/s")
        XCTAssertLessThan(worstSnap, 5.5, "speed at the moment the heading flips, m/s")
    }
}
