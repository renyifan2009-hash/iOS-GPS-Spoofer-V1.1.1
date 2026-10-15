import XCTest
@testable import PhoneOnlyCore

final class StandaloneRouteTests: XCTestCase {
    private let a = StandaloneRoute.Point(0, 0)
    private let b = StandaloneRoute.Point(0, 0.001)

    func testWaitTravelAndDestinationHold() throws {
        let route = try StandaloneRoute(legs: [[a, b]], waits: [2, 3], speed: 10, repeatMode: "once")
        XCTAssertEqual(route.sample(at: 1).point, a)
        XCTAssertFalse(route.sample(at: 1).moving)
        let halfway = route.sample(at: 2 + StandaloneRoute.distance(a, b) / 20)
        XCTAssertEqual(halfway.point.longitude, 0.0005, accuracy: 1e-8)
        XCTAssertTrue(halfway.moving)
        let waitAtEnd = route.sample(at: route.duration - 1)
        XCTAssertEqual(waitAtEnd.point, b)
        XCTAssertFalse(waitAtEnd.finished)
        XCTAssertFalse(waitAtEnd.moving)
        XCTAssertTrue(route.sample(at: route.duration).finished)
        XCTAssertEqual(route.sample(at: route.duration * 2).point, b)
    }

    func testPingPongReturnsWithoutJumping() throws {
        let route = try StandaloneRoute(legs: [[a, b]], waits: [0, 2], speed: 10, repeatMode: "pingPong")
        let t = StandaloneRoute.distance(a, b) / 10
        XCTAssertEqual(route.sample(at: t + 1).point, b)
        XCTAssertEqual(route.sample(at: t * 1.5 + 2).point.longitude, 0.0005, accuracy: 1e-8)
        XCTAssertEqual(route.sample(at: route.duration).point, a)
        XCTAssertFalse(route.sample(at: route.duration).finished)
    }

    func testLoopRequiresAndUsesReturnLeg() throws {
        XCTAssertThrowsError(try StandaloneRoute(legs: [[a, b]], waits: [0, 0], speed: 10, repeatMode: "loop"))
        let route = try StandaloneRoute(legs: [[a, b], [b, a]], waits: [0, 0, 0], speed: 10, repeatMode: "loop")
        XCTAssertEqual(route.sample(at: route.duration * 2).point, a)
        XCTAssertFalse(route.sample(at: route.duration * 2).finished)
    }

    func testDatelineTakesShortPath() throws {
        let route = try StandaloneRoute(legs: [[.init(0, 179.999), .init(0, -179.999)]],
                                        waits: [0, 0], speed: 10, repeatMode: "once")
        XCTAssertLessThan(route.duration, 25)
        XCTAssertEqual(abs(route.sample(at: route.duration / 2).point.longitude), 180, accuracy: 1e-7)
    }

    func testRejectsInvalidAndDegenerateInput() {
        XCTAssertThrowsError(try StandaloneRoute(legs: [[a, a]], waits: [10, 10], speed: 1, repeatMode: "once"))
        XCTAssertThrowsError(try StandaloneRoute(legs: [[a, b]], waits: [0, .infinity], speed: 1, repeatMode: "once"))
        XCTAssertThrowsError(try StandaloneRoute(legs: [[a, b]], waits: [0, 0], speed: .nan, repeatMode: "once"))
        XCTAssertThrowsError(try StandaloneRoute(legs: [[a, b]], waits: [0, 0], speed: 71, repeatMode: "once"))
        XCTAssertThrowsError(try StandaloneRoute(legs: [[a, b]], waits: [0, 0], speed: 1, repeatMode: "unknown"))
        XCTAssertThrowsError(try StandaloneRoute(legs: [[a, .init(90, 0)]], waits: [0, 0], speed: 1, repeatMode: "once"))
    }

    func testDiscontinuousLegsAreRefused() {
        XCTAssertThrowsError(try StandaloneRoute(legs: [[a, b], [a, b]], waits: [0, 0, 0], speed: 1, repeatMode: "once"))
    }

    func testNonfiniteElapsedIsSafe() throws {
        let route = try StandaloneRoute(legs: [[a, b]], waits: [0, 0], speed: 1, repeatMode: "once")
        XCTAssertEqual(route.sample(at: .infinity).point, a)
        XCTAssertEqual(route.sample(at: -.infinity).point, a)
        XCTAssertEqual(route.sample(at: .nan).point, a)
    }

    func testItSaysWhichStopItIsWaitingAtAndForHowLong() throws {
        let a = StandaloneRoute.Point(0, 0), b = StandaloneRoute.Point(0, 0.001), c = StandaloneRoute.Point(0, 0.002)
        let route = try StandaloneRoute(legs: [[a, b], [b, c]], waits: [30, 20, 0], speed: 10, repeatMode: "once")
        let start = try XCTUnwrap(route.waiting(at: 10))
        XCTAssertEqual(start.stop, 0)                           // before leaving
        XCTAssertEqual(start.remaining, 20, accuracy: 1e-9)
        XCTAssertNil(route.waiting(at: 35), "travelling")
        let leg = StandaloneRoute.distance(a, b) / 10
        let rest = try XCTUnwrap(route.waiting(at: 30 + leg + 5))
        XCTAssertEqual(rest.stop, 1)
        XCTAssertEqual(rest.remaining, 15, accuracy: 1e-6)
        XCTAssertNil(route.waiting(at: route.duration + 10), "arrived")
        XCTAssertEqual(route.waiting(at: .nan)?.stop, 0, "a time that isn't a number reads as the start, like sample(at:)")
    }
}
