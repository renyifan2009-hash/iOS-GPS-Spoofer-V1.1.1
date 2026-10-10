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
}
