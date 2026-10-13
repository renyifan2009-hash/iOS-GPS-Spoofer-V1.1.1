import XCTest
@testable import RemoteAPI

final class RemoteControlsProtocolTests: XCTestCase {
    // MARK: - Status from older and newer builds

    func testAStatusFromAnOlderMacStillDecodes() throws {
        // What a Mac before the joystick work sends: none of the new fields.
        let json = """
        {"connected":true,"spoofing":true,"latitude":37.3,"longitude":-122.0,"phase":"active",
         "serverName":"Mac","engine":"Live"}
        """
        let status = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.spoofing)
        XCTAssertNil(status.activity)
        XCTAssertNil(status.speed)
        XCTAssertNil(status.routeProgress)
        XCTAssertNil(status.autoStopAt)
    }

    func testTheNewStatusFieldsRoundTrip() throws {
        let status = RemoteStatus(connected: true, spoofing: true, latitude: 1, longitude: 2, phase: .active,
                                  serverName: "Mac", activity: "route", speed: 13.4, heading: 270,
                                  routeProgress: 0.42, routePaused: false, autoStopAt: 1_800_000_900)
        let data = try RemoteAPI.makeEncoder().encode(status)
        let back = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: data)
        XCTAssertEqual(back, status)
    }

    func testAStatusWithKeysThisBuildDoesNotKnowStillDecodes() throws {
        let json = """
        {"connected":false,"spoofing":false,"phase":"idle","serverName":"Mac","somethingNew":{"a":1}}
        """
        XCTAssertNoThrow(try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: Data(json.utf8)))
    }

    // MARK: - Joystick

    func testJoystickRequestsAreChecked() {
        XCTAssertTrue(JoystickRequest(heading: 0, speed: 0).isValid)
        XCTAssertTrue(JoystickRequest(heading: 359.9, speed: 70).isValid)
        XCTAssertFalse(JoystickRequest(heading: 360, speed: 1).isValid)
        XCTAssertFalse(JoystickRequest(heading: -1, speed: 1).isValid)
        XCTAssertFalse(JoystickRequest(heading: 90, speed: -0.1).isValid)
        XCTAssertFalse(JoystickRequest(heading: 90, speed: 70.1).isValid)
        XCTAssertFalse(JoystickRequest(heading: .nan, speed: 1).isValid)
        XCTAssertFalse(JoystickRequest(heading: 90, speed: .infinity).isValid)
    }

    func testNormalizingWrapsTheHeadingAndHoldsTheSpeed() {
        XCTAssertEqual(JoystickRequest(heading: 370, speed: 5).normalized, JoystickRequest(heading: 10, speed: 5))
        XCTAssertEqual(JoystickRequest(heading: -90, speed: 5).normalized, JoystickRequest(heading: 270, speed: 5))
        XCTAssertEqual(JoystickRequest(heading: 720, speed: 5).normalized.heading, 0)
        XCTAssertEqual(JoystickRequest(heading: 10, speed: 500).normalized.speed, 70)
        XCTAssertEqual(JoystickRequest(heading: 10, speed: -3).normalized.speed, 0)
        XCTAssertEqual(JoystickRequest(heading: .nan, speed: .nan).normalized, JoystickRequest(heading: 0, speed: 0))
        for h in stride(from: -1_000.0, through: 1_000, by: 37.5) {
            XCTAssertTrue(JoystickRequest(heading: h, speed: 3).normalized.isValid, "\(h)")
        }
    }

    // MARK: - Auto-stop

    func testAutoStopMinutesAreBounded() {
        XCTAssertTrue(AutoStopRequest(minutes: 0).isValid)
        XCTAssertTrue(AutoStopRequest(minutes: 1_440).isValid)
        XCTAssertFalse(AutoStopRequest(minutes: -1).isValid)
        XCTAssertFalse(AutoStopRequest(minutes: 1_441).isValid)
    }
}
