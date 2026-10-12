import XCTest
@testable import SpooferCore

/// Jumping around a trip (the progress slider, a changed route) while one of the
/// user's own stops is in the plan.
final class TripSeekTests: XCTestCase {
    private let a = GeoPoint(37, -122)

    private func planner() -> TripPlanner {
        TripPlanner(path: RoutePath([a, a.moved(by: 2000, bearing: 0)]), loopMode: .once,
                    settings: TripSettings(topSpeed: 15),
                    waypointStops: [WaypointStop(index: 1, distance: 500, wait: 60)])
    }

    private func isWaiting(at waypoint: Int, _ status: TripStatus) -> Bool {
        if case .stopped(.waypoint(waypoint), _) = status { return true }
        return false
    }

    func testJumpingPastAStopDoesNotWaitAtItAfterTheFact() {
        var trip = TripController(planner: planner(), seed: 1)
        var position = trip.step(dt: 0.5, lapDistance: 0, lap: 0)
        XCTAssertGreaterThan(position, 0)
        // Seek to 1500 m, a kilometre beyond the stop at 500 m.
        position = 1500
        let moved = trip.step(dt: 0.5, lapDistance: position, lap: 0)
        XCTAssertEqual(trip.status, .moving)
        XCTAssertGreaterThan(moved, 0)
        // And it carries on towards the end without ever stopping for it.
        for _ in 0..<600 {
            position += trip.step(dt: 0.5, lapDistance: position, lap: 0)
            XCTAssertFalse(isWaiting(at: 1, trip.status))
        }
        XCTAssertGreaterThan(position, 1900)
    }

    func testJumpingBackBeforeAStopWaitsAtItAgain() {
        var trip = TripController(planner: planner(), seed: 1)
        var position = 0.0
        // Drive past the stop (it waits 60 s) and on to 1400 m.
        for _ in 0..<2000 where position < 1400 {
            position += trip.step(dt: 0.5, lapDistance: position, lap: 0)
        }
        XCTAssertGreaterThanOrEqual(position, 1400)
        // Seek back to 100 m: the stop at 500 m is ahead again.
        position = 100
        var stoppedAt: Double?
        for _ in 0..<400 {
            position += trip.step(dt: 0.5, lapDistance: position, lap: 0)
            if isWaiting(at: 1, trip.status) {
                stoppedAt = position
                break
            }
        }
        XCTAssertEqual(stoppedAt ?? -1, 500, accuracy: 1)
    }
}
