import PhoneOnlyCore
import XCTest
@testable import RemoteAPI

/// The waits a route makes at its stops, over the wire: the iPhone sends how long to wait at each stop (the
/// start's wait is "leave after"), and the Mac says why it is standing still and for how much longer.
final class RouteWaitProtocolTests: XCTestCase {
    func testTheRouteWaitRoundTrips() throws {
        let status = RemoteStatus(connected: true, spoofing: true, phase: .active, serverName: "Mac",
                                  activity: "route", speed: 0, routeProgress: 0, routePaused: false,
                                  routeWait: RouteWait(reason: "stop", stop: 0, remaining: 1781.5))
        let data = try RemoteAPI.makeEncoder().encode(status)
        let back = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: data)
        XCTAssertEqual(back, status)
        XCTAssertEqual(back.routeWait?.stop, 0)
        XCTAssertEqual(back.routeWait?.remaining ?? 0, 1781.5, accuracy: 1e-9)
    }

    func testAStatusFromAMacWithoutRouteWaitsStillDecodes() throws {
        let json = """
        {"connected":true,"spoofing":true,"phase":"active","serverName":"Mac","activity":"route",
         "routeProgress":0.1,"routePaused":false}
        """
        let status = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.routeWait)
        XCTAssertEqual(status.activity, "route")
    }

    func testArrivedHasNoTimeLeft() throws {
        let json = """
        {"connected":true,"spoofing":true,"phase":"active","serverName":"Mac","routeWait":{"reason":"arrived"}}
        """
        let status = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.routeWait, RouteWait(reason: "arrived"))
        XCTAssertNil(status.routeWait?.remaining)
        XCTAssertNil(status.routeWait?.stop)
    }

    func testAWaitBeforeLeavingIsAWaitAtTheFirstStop() {
        let route = RouteRequest(waypoints: [.init(latitude: 37.33, longitude: -122.01, wait: 1800),
                                             .init(latitude: 37.34, longitude: -122.02)],
                                 followRoads: true, travelMode: "driving", loopMode: "once", speed: 13.4,
                                 realistic: true, timeOfDayTraffic: false, name: "Friend's house")
        XCTAssertTrue(route.isValid)
    }

    func testWaitsUpToADayAreAcceptedAndLongerOnesAreNot() {
        func route(wait: Double) -> RouteRequest {
            RouteRequest(waypoints: [.init(latitude: 1, longitude: 1), .init(latitude: 1.01, longitude: 1, wait: wait),
                                     .init(latitude: 1.02, longitude: 1)],
                         followRoads: false, travelMode: "walking", loopMode: "once", speed: 1.4,
                         realistic: true, timeOfDayTraffic: false, name: nil)
        }
        XCTAssertTrue(route(wait: 24 * 3600).isValid)
        XCTAssertFalse(route(wait: 24 * 3600 + 1).isValid)
        XCTAssertFalse(route(wait: .infinity).isValid)
        XCTAssertFalse(route(wait: -1).isValid)
    }

    func testTheMacAndTheIPhoneAgreeOnTheLongestWait() {
        XCTAssertEqual(RemoteAPI.maxWaitSeconds, WaitDuration.maxSeconds)
    }
}
