import Foundation
import RemoteAPI
import SpooferCore
import XCTest
@testable import SpooferRemote

final class RouteRunnerTests: XCTestCase {
    /// A short straight route near Apple Park (two points ~350 m apart, due east).
    private func straightRequest(realistic: Bool, speed: Double = 10, loop: String = "once") -> RouteRequest {
        RouteRequest(waypoints: [.init(latitude: 37.3349, longitude: -122.0090),
                                 .init(latitude: 37.3349, longitude: -122.0050)],
                     travelMode: "driving", loopMode: loop, speed: speed, realistic: realistic)
    }

    func testBuildsAndPlaysFromStartToEnd() throws {
        let runner = try RouteRunner.build(from: straightRequest(realistic: false, speed: 10))
        XCTAssertFalse(runner.track.isEmpty)
        XCTAssertGreaterThan(runner.duration, 0)

        let begin = runner.position(at: 0)
        XCTAssertEqual(begin.point.latitude, 37.3349, accuracy: 1e-4)
        XCTAssertEqual(begin.point.longitude, -122.0090, accuracy: 1e-4)
        XCTAssertFalse(begin.finished)

        let end = runner.position(at: runner.duration + 10)
        XCTAssertEqual(end.point.longitude, -122.0050, accuracy: 1e-4)
        XCTAssertTrue(end.finished)

        // Progresses eastward over time (longitude rises from -122.0090 toward -122.0050).
        let early = runner.position(at: runner.duration * 0.25).point.longitude
        let late = runner.position(at: runner.duration * 0.75).point.longitude
        XCTAssertLessThan(begin.point.longitude, early)
        XCTAssertLessThan(early, late)
    }

    func testRealisticIsNeverFasterThanConstantSpeed() throws {
        let naive = try RouteRunner.build(from: straightRequest(realistic: false, speed: 10))
        let realistic = try RouteRunner.build(from: straightRequest(realistic: true, speed: 10))
        XCTAssertGreaterThanOrEqual(realistic.duration, naive.duration * 0.95)
        XCTAssertFalse(realistic.track.isEmpty)
    }

    func testWaypointWaitLengthensTheTrip() throws {
        func request(middleWait: Double?) -> RouteRequest {
            RouteRequest(waypoints: [
                .init(latitude: 37.3349, longitude: -122.0090),
                .init(latitude: 37.3349, longitude: -122.0050, wait: middleWait),
                .init(latitude: 37.3349, longitude: -122.0010),
            ], travelMode: "driving", loopMode: "once", speed: 10, realistic: true)
        }
        let without = try RouteRunner.build(from: request(middleWait: nil))
        let withWait = try RouteRunner.build(from: request(middleWait: 300))
        XCTAssertGreaterThan(withWait.duration, without.duration + 250)
    }

    /// "Leave after 30 s": the route holds the start, then goes. With realistic trips off too.
    func testAWaitAtTheStartHoldsTheStartFirst() throws {
        for realistic in [true, false] {
            var request = straightRequest(realistic: realistic)
            request.waypoints[0].wait = 30
            let runner = try RouteRunner.build(from: request)
            let start = runner.position(at: 0).point
            for t in [5.0, 15, 28] {
                XCTAssertLessThan(runner.position(at: t).point.distance(to: start), 1,
                                  "realistic \(realistic): still at the start after \(t) s")
            }
            XCTAssertGreaterThan(runner.position(at: 60).point.distance(to: start), 50,
                                 "realistic \(realistic): on its way a while after the wait")
            // The wait, plus (with realistic trips off) a few seconds of speeding up and braking that the
            // plain constant-speed run doesn't have.
            let plain = try RouteRunner.build(from: straightRequest(realistic: realistic))
            let extra = runner.duration - plain.duration
            XCTAssertGreaterThanOrEqual(extra, 29.5, "realistic \(realistic)")
            XCTAssertLessThan(extra, 40, "realistic \(realistic)")
        }
    }

    func testALoopWaitsBeforeLeavingOnlyOnceAndShowsNoProgressMeanwhile() throws {
        var request = straightRequest(realistic: true, loop: "loop")
        request.waypoints[0].wait = 20
        let runner = try RouteRunner.build(from: request)
        let start = runner.start
        XCTAssertEqual(runner.leaves, 20, accuracy: 1)
        XCTAssertEqual(runner.progress(at: 10), 0, "parked at the start: no progress yet")
        XCTAssertLessThan(runner.position(at: 10).point.distance(to: start), 1)
        // Into the second lap: having waited at the start as it came round, it sets straight off again.
        let secondLap = runner.duration + 3
        XCTAssertGreaterThan(runner.position(at: secondLap).point.distance(to: start), 1,
                             "the wait before leaving isn't repeated every lap")
        XCTAssertGreaterThan(runner.progress(at: secondLap), 0)
    }

    func testLoopWrapsAndNeverFinishes() throws {
        let runner = try RouteRunner.build(from: straightRequest(realistic: false, speed: 10, loop: "loop"))
        XCTAssertTrue(runner.wraps)
        XCTAssertGreaterThan(runner.duration, 0)
        let atFive = runner.position(at: 5)
        let wrapped = runner.position(at: runner.duration + 5)
        XCTAssertEqual(atFive.point.latitude, wrapped.point.latitude, accuracy: 1e-6)
        XCTAssertEqual(atFive.point.longitude, wrapped.point.longitude, accuracy: 1e-6)
        XCTAssertFalse(wrapped.finished)
    }

    func testRejectsInvalidRoutes() {
        XCTAssertThrowsError(try RouteRunner.build(
            from: RouteRequest(waypoints: [.init(latitude: 1, longitude: 2)])))              // one point
        XCTAssertThrowsError(try RouteRunner.build(from: RouteRequest(waypoints: [           // same spot twice
            .init(latitude: 1, longitude: 2), .init(latitude: 1, longitude: 2)])))
    }

    func testProgressRunsFromZeroToOne() throws {
        let runner = try RouteRunner.build(from: straightRequest(realistic: false, speed: 10))
        XCTAssertEqual(runner.progress(at: 0), 0)
        XCTAssertEqual(runner.progress(at: runner.duration / 2), 0.5, accuracy: 0.01)
        XCTAssertEqual(runner.progress(at: runner.duration), 1, accuracy: 1e-9)
        XCTAssertEqual(runner.progress(at: runner.duration * 10), 1, "a one-way route stays at the end")
        for bad in [-5.0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(runner.progress(at: bad), 0, "\(bad) is not a time: it reads as the start, never a crash")
        }
    }

    func testProgressStartsOverEachLapOfALoop() throws {
        let runner = try RouteRunner.build(from: straightRequest(realistic: false, speed: 10, loop: "loop"))
        XCTAssertEqual(runner.progress(at: runner.duration * 0.25), 0.25, accuracy: 0.01)
        XCTAssertEqual(runner.progress(at: runner.duration * 1.25), 0.25, accuracy: 0.01)
        XCTAssertEqual(runner.progress(at: runner.duration * 7.5), 0.5, accuracy: 0.01)
    }
}
