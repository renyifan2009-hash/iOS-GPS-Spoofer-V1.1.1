import RemoteAPI
import SpooferCore
import XCTest
@testable import SpooferRemote

final class JoystickMotionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let start = GeoPoint(37.3349, -122.0090)

    func testItStopsWhenTheIPhoneGoesQuiet() {
        let motion = JoystickMotion(heading: 90, speed: 5, receivedAt: t0)
        XCTAssertEqual(motion.effectiveSpeed(at: t0), 5)
        XCTAssertEqual(motion.effectiveSpeed(at: t0.addingTimeInterval(RemoteAPI.joystickTimeout)), 5, "right at the limit still counts")
        XCTAssertEqual(motion.effectiveSpeed(at: t0.addingTimeInterval(RemoteAPI.joystickTimeout + 0.01)), 0)
        XCTAssertTrue(motion.isExpired(at: t0.addingTimeInterval(60)))
    }

    func testAStaleRequestDoesNotMoveTheLocation() {
        let motion = JoystickMotion(heading: 0, speed: 10, receivedAt: t0)
        let later = t0.addingTimeInterval(30)
        XCTAssertEqual(motion.step(from: start, dt: 1, now: later), start)
    }

    func testMovingNorthRaisesTheLatitudeByTheRightAmount() {
        let motion = JoystickMotion(heading: 0, speed: 10, receivedAt: t0)
        let next = motion.step(from: start, dt: 1, now: t0)
        XCTAssertGreaterThan(next.latitude, start.latitude)
        XCTAssertEqual(next.longitude, start.longitude, accuracy: 1e-9)
        XCTAssertEqual(start.distance(to: next), 10, accuracy: 0.05)
    }

    func testMovingEastRaisesTheLongitude() {
        let motion = JoystickMotion(heading: 90, speed: 4, receivedAt: t0)
        let next = motion.step(from: start, dt: 2.5, now: t0)
        XCTAssertGreaterThan(next.longitude, start.longitude)
        XCTAssertEqual(start.distance(to: next), 10, accuracy: 0.05)
    }

    func testSpeedZeroStandsStill() {
        let motion = JoystickMotion(heading: 123, speed: 0, receivedAt: t0)
        XCTAssertEqual(motion.step(from: start, dt: 1, now: t0), start)
    }

    func testNonsenseTimeStepsDoNotMove() {
        let motion = JoystickMotion(heading: 45, speed: 5, receivedAt: t0)
        for dt in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertEqual(motion.step(from: start, dt: dt, now: t0), start, "\(dt)")
        }
    }

    func testARequestIsNormalizedWhenItArrives() {
        let wild = JoystickMotion(JoystickRequest(heading: 450, speed: 500), receivedAt: t0)
        XCTAssertEqual(wild.heading, 90)
        XCTAssertEqual(wild.speed, 70)
        let nan = JoystickMotion(JoystickRequest(heading: .nan, speed: .nan), receivedAt: t0)
        XCTAssertEqual(nan.speed, 0)
    }

    func testAnUnbrokenHeldDirectionKeepsGoingAndAfterReleaseItStops() {
        // Resent every 0.5 s while held: ten seconds at 3 m/s is 30 m. Then silence.
        var point = start
        var motion = JoystickMotion(heading: 180, speed: 3, receivedAt: t0)
        var now = t0
        for tick in 1...40 {                     // 10 s in quarter-second ticks
            now = t0.addingTimeInterval(Double(tick) * 0.25)
            if tick % 2 == 0 { motion.receivedAt = now }    // the iPhone resends every 0.5 s
            point = motion.step(from: point, dt: 0.25, now: now)
        }
        XCTAssertEqual(start.distance(to: point), 30, accuracy: 0.3)
        let held = point
        for tick in 1...40 {                     // the iPhone goes quiet
            now = now.addingTimeInterval(0.25)
            point = motion.step(from: point, dt: 0.25, now: now)
            _ = tick
        }
        // It kept going for at most the timeout after the last request, then stopped.
        XCTAssertLessThanOrEqual(held.distance(to: point), 3 * RemoteAPI.joystickTimeout + 0.1)
    }
}
