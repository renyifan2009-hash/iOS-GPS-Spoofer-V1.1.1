import XCTest
@testable import SpooferCore

/// Where a waypoint of the user's is along a route that does not go exactly through it.
final class WaypointDistanceTests: XCTestCase {
    private let a = GeoPoint(37, -122)

    func testWaypointsThatAreNotOnACornerAreFoundAlongTheRoute() {
        let b = a.moved(by: 300, bearing: 0), c = b.moved(by: 500, bearing: 90)
        let path = RoutePath([a, a.moved(by: 150, bearing: 0), b, b.moved(by: 250, bearing: 90), c])
        let matcher = RouteMatcher(path: path)
        // Midway along a straight leg (no point of the route is near it), and 8 m beside a corner.
        let midLeg = a.moved(by: 75, bearing: 0)
        let besideCorner = b.moved(by: 8, bearing: 270)
        let distances = matcher.distances(ofWaypoints: [a, midLeg, besideCorner, c])
        XCTAssertEqual(distances[0], 0, accuracy: 0.5)
        XCTAssertEqual(distances[1], 75, accuracy: 1)
        XCTAssertEqual(distances[2], 300, accuracy: 1)
        XCTAssertEqual(distances[3], 800, accuracy: 1)
    }

    func testAWaypointOffTheRouteKeepsItsPlaceInTheOrder() {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let matcher = RouteMatcher(path: path)
        // The second is nowhere near: it takes the distance of the one before, never an earlier one.
        let far = a.moved(by: 5000, bearing: 90)
        let distances = matcher.distances(ofWaypoints: [a.moved(by: 600, bearing: 0), far, a.moved(by: 900, bearing: 0)])
        XCTAssertEqual(distances[0], 600, accuracy: 1)
        XCTAssertEqual(distances[1], distances[0], accuracy: 1e-9)
        XCTAssertEqual(distances[2], 900, accuracy: 1)
    }

    func testAWaypointOnTheWayBackTakesTheNextVisit() {
        // Out 1 km and back along the same road; a waypoint beside it is passed twice.
        let top = a.moved(by: 1000, bearing: 0)
        let matcher = RouteMatcher(path: RoutePath([a, top, a]))
        let beside = a.moved(by: 500, bearing: 0).moved(by: 4, bearing: 90)
        let distances = matcher.distances(ofWaypoints: [a, beside, top, beside, a])
        XCTAssertEqual(distances[0], 0, accuracy: 0.5)
        XCTAssertEqual(distances[1], 500, accuracy: 1)
        XCTAssertEqual(distances[2], 1000, accuracy: 1)
        XCTAssertEqual(distances[3], 1500, accuracy: 1)      // the second time past it
        XCTAssertEqual(distances[4], 2000, accuracy: 1)
    }
}
