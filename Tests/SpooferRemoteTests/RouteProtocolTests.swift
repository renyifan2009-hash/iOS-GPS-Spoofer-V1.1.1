import Foundation
import RemoteAPI
import XCTest

final class RouteProtocolTests: XCTestCase {
    private func roundTrip(_ request: RouteRequest) throws -> RouteRequest {
        let data = try RemoteAPI.makeEncoder().encode(request)
        return try RemoteAPI.makeDecoder().decode(RouteRequest.self, from: data)
    }

    func testRoundTripsOverTheWire() throws {
        let request = RouteRequest(
            waypoints: [.init(latitude: 37.3349, longitude: -122.0090),
                        .init(latitude: 37.3318, longitude: -122.0312, wait: 300),
                        .init(latitude: 37.3270, longitude: -122.0320)],
            followRoads: true, travelMode: "driving", loopMode: "pingPong",
            speed: 16, realistic: true, timeOfDayTraffic: true, name: "Commute")
        XCTAssertEqual(try roundTrip(request), request)
    }

    func testValidatesWaypointsAndModes() {
        let ok = RouteRequest(waypoints: [.init(latitude: 1, longitude: 2), .init(latitude: 3, longitude: 4)])
        XCTAssertTrue(ok.isValid)
        XCTAssertFalse(RouteRequest(waypoints: [.init(latitude: 1, longitude: 2)]).isValid)   // too few
        XCTAssertFalse(RouteRequest(waypoints: [.init(latitude: 1, longitude: 2),
                                                .init(latitude: 95, longitude: 4)]).isValid)   // bad coord
        XCTAssertFalse(RouteRequest(waypoints: ok.waypoints, travelMode: "flying").isValid)
        XCTAssertFalse(RouteRequest(waypoints: ok.waypoints, loopMode: "spiral").isValid)
        XCTAssertFalse(RouteRequest(waypoints: ok.waypoints, speed: 0).isValid)
        XCTAssertFalse(RouteRequest(waypoints: [.init(latitude: 1, longitude: 2, wait: -5),
                                                .init(latitude: 3, longitude: 4)]).isValid)
    }

    func testLenientDecodingFillsDefaults() throws {
        // An older iPhone build that only sends waypoints + speed.
        let json = #"{"waypoints":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}],"speed":5}"#
        let request = try RemoteAPI.makeDecoder().decode(RouteRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.waypoints.count, 2)
        XCTAssertEqual(request.speed, 5)
        XCTAssertEqual(request.travelMode, "walking")
        XCTAssertEqual(request.loopMode, "once")
        XCTAssertTrue(request.realistic)
        XCTAssertFalse(request.timeOfDayTraffic)
    }
}
