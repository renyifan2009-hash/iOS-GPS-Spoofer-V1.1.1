import XCTest
@testable import SpooferCore

/// A wait at the first stop means "wait here before leaving": the trip sits at the start for that long, then
/// drives. A loop or a back-and-forth also waits there each time it comes back round, as before.
final class DepartureWaitTests: XCTestCase {
    private static let a = GeoPoint(37, -122)

    private static func line(_ metres: Double) -> RoutePath {
        RoutePath([a, a.moved(by: metres, bearing: 0)])
    }

    private static func square() -> RoutePath {
        let b = a.moved(by: 300, bearing: 0), c = b.moved(by: 300, bearing: 90)
        return RoutePath([a, b, c, a])
    }

    private func planner(_ path: RoutePath, _ loop: LoopMode, startWait: Double, stops: [WaypointStop] = []) -> TripPlanner {
        TripPlanner(path: path, loopMode: loop, settings: TripSettings(topSpeed: 10, breaks: false),
                    waypointStops: [WaypointStop(index: 0, distance: 0, wait: startWait)] + stops)
    }

    func testAOneWayTripWaitsAtTheStartThenLeaves() {
        let trip = planner(Self.line(1000), .once, startWait: 30)
        var playback = RoutePlayback(path: trip.path, loopMode: .once)
        var controller = TripController(planner: trip, seed: 1)
        var t = 0.0, leftAt: Double?
        var remainingSeen: [Double] = []
        while t < 600, !playback.isFinished {
            playback.advance(by: controller.step(dt: 0.5, lapDistance: playback.lapDistance, lap: playback.lap))
            t += 0.5
            if case .stopped(.waypoint(0), let remaining?) = controller.status {
                remainingSeen.append(remaining)
                XCTAssertEqual(playback.travelled, 0, accuracy: 1e-9, "it must not creep forward while waiting")
            } else if leftAt == nil, playback.travelled > 0 {
                leftAt = t
            }
        }
        XCTAssertTrue(playback.isFinished, "it still gets there")
        XCTAssertEqual(leftAt ?? 0, 30, accuracy: 1.01, "it leaves after the 30 s wait")
        XCTAssertEqual(remainingSeen.first ?? 0, 30, accuracy: 0.01)      // the full wait shows first
        XCTAssertEqual(remainingSeen, remainingSeen.sorted(by: >), "the countdown only goes down")
    }

    func testOnlyTheFirstLapOfALoopWaitsBeforeLeaving() {
        let loop = planner(Self.square(), .loop, startWait: 20)
        let first = loop.lapPlan(lap: 0, seed: 1).stops.filter { $0.reason == .waypoint(0) }.map(\.distance)
        let later = loop.lapPlan(lap: 1, seed: 1).stops.filter { $0.reason == .waypoint(0) }.map(\.distance)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first ?? -1, 0, accuracy: 1e-9)              // before leaving
        XCTAssertEqual(first.last ?? -1, loop.path.length, accuracy: 1)   // and on coming back round
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(later.first ?? -1, loop.path.length, accuracy: 1)
    }

    func testABackAndForthWaitsBeforeLeavingAndOnReturning() {
        let pingPong = planner(Self.line(800), .pingPong, startWait: 15)
        let first = pingPong.lapPlan(lap: 0, seed: 1).stops.filter { $0.reason == .waypoint(0) }.map(\.distance)
        XCTAssertEqual(first.first ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(pingPong.lapPlan(lap: 1, seed: 1).stops.filter { $0.reason == .waypoint(0) }.count, 1)
    }

    func testNoWaitAtTheStartChangesNothing() {
        let without = TripPlanner(path: Self.line(1000), loopMode: .once, settings: TripSettings(topSpeed: 10, breaks: false))
        XCTAssertEqual(without.lapPlan(lap: 0, seed: 1).stops.map(\.reason), [.destination])
    }

    func testTheExpectedTimeOfAOneWayTripIncludesTheWaitBeforeLeaving() {
        let plain = TripPlanner(path: Self.line(1000), loopMode: .once, settings: TripSettings(topSpeed: 10, breaks: false))
        let waiting = planner(Self.line(1000), .once, startWait: 1800)
        XCTAssertEqual(waiting.expectedLapTime() - plain.expectedLapTime(), 1800, accuracy: 1)
    }

    func testTheLapTimeOfALoopCountsTheStartWaitOncePerLap() {
        let plain = TripPlanner(path: Self.square(), loopMode: .loop, settings: TripSettings(topSpeed: 10, breaks: false))
        let waiting = planner(Self.square(), .loop, startWait: 600)
        // One wait a lap (when it comes back round); the one-off wait before leaving is not a lap's time.
        // A few seconds more: it brakes to a stop there and speeds up again, where the plain loop rolls through.
        XCTAssertEqual(waiting.expectedLapTime() - plain.expectedLapTime(), 600, accuracy: 5)
    }

    func testTimeToTheEndCountsWhatIsLeftOfTheWait() {
        let trip = planner(Self.line(1000), .once, startWait: 120)
        var controller = TripController(planner: trip, seed: 1)
        for _ in 0..<20 { _ = controller.step(dt: 1, lapDistance: 0, lap: 0) }   // 20 s into the wait
        let plain = TripController(planner: TripPlanner(path: Self.line(1000), loopMode: .once,
                                                        settings: TripSettings(topSpeed: 10, breaks: false)), seed: 1)
        XCTAssertEqual(controller.timeToLapEnd(from: 0) - plain.timeToLapEnd(from: 0), 100, accuracy: 1.5)
    }

    func testRestStopsInBetweenStillWait() {
        let trip = planner(Self.line(1000), .once, startWait: 10,
                           stops: [WaypointStop(index: 1, distance: 500, wait: 20)])
        XCTAssertEqual(trip.lapPlan(lap: 0, seed: 1).stops.map(\.reason), [.waypoint(0), .waypoint(1), .destination])
    }

    // MARK: Changing the wait while it counts down

    /// 60 s into a 10 min wait before leaving.
    private func waitingAtTheStart() -> TripController {
        var trip = TripController(planner: planner(Self.line(1000), .once, startWait: 600), seed: 1)
        for _ in 0..<60 { _ = trip.step(dt: 1, lapDistance: 0, lap: 0) }
        return trip
    }

    private func left(_ trip: TripController) -> Double? {
        if case .stopped(.waypoint(0), let remaining) = trip.status { return remaining }
        return nil
    }

    func testShorteningTheWaitCountsFromWhenItStopped() {
        var trip = waitingAtTheStart()
        trip.update(waypointStops: [WaypointStop(index: 0, distance: 0, wait: 120)])
        _ = trip.step(dt: 1, lapDistance: 0, lap: 0)
        XCTAssertEqual(left(trip) ?? -1, 59, accuracy: 1.01, "2 min wait, 61 s gone: about a minute left")
    }

    func testLengtheningTheWaitCountsFromWhenItStopped() {
        var trip = waitingAtTheStart()
        trip.update(waypointStops: [WaypointStop(index: 0, distance: 0, wait: 1800)])
        _ = trip.step(dt: 1, lapDistance: 0, lap: 0)
        XCTAssertEqual(left(trip) ?? -1, 1739, accuracy: 1.01)
    }

    func testRemovingTheWaitOrShorteningItBelowWhatHasPassedLeavesNow() {
        for stops in [[], [WaypointStop(index: 0, distance: 0, wait: 30)]] {
            var trip = waitingAtTheStart()
            trip.update(waypointStops: stops)
            var playback = RoutePlayback(path: trip.planner.path, loopMode: .once)
            for _ in 0..<10 { playback.advance(by: trip.step(dt: 1, lapDistance: playback.lapDistance, lap: playback.lap)) }
            XCTAssertGreaterThan(playback.travelled, 5, "leaves straight away (stops: \(stops.count))")
            XCTAssertNil(left(trip))
        }
    }

    func testARebuiltTripCarriesOnWithTheTimeAlreadyWaited() {
        let old = waitingAtTheStart()
        var fresh = TripController(planner: planner(Self.line(1200), .once, startWait: 600), seed: 2)
        fresh.carryOverWait(from: old)
        XCTAssertEqual(left(fresh) ?? -1, 540, accuracy: 1.01, "the route was edited: 9 min left, not 10")
        _ = fresh.step(dt: 1, lapDistance: 0, lap: 0)
        XCTAssertEqual(left(fresh) ?? -1, 539, accuracy: 1.01)
    }

    func testCarryingOverIgnoresATripThatWasNotWaiting() {
        let moving = TripController(planner: planner(Self.line(1000), .once, startWait: 0), seed: 1)
        var fresh = TripController(planner: planner(Self.line(1000), .once, startWait: 600), seed: 2)
        fresh.carryOverWait(from: moving)
        _ = fresh.step(dt: 1, lapDistance: 0, lap: 0)
        XCTAssertEqual(left(fresh) ?? -1, 600, accuracy: 1.01, "a new wait starts from the top")
    }
}
