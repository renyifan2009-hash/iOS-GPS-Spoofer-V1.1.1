import XCTest
@testable import PhoneOnlyCore

final class JoystickInputTests: XCTestCase {
    func testRestingThumbIsIdle() {
        XCTAssertEqual(JoystickInput.make(x: 0, y: 0, topSpeed: 10), .idle)
        XCTAssertEqual(JoystickInput.make(x: 0.05, y: -0.05, topSpeed: 10), .idle)
        XCTAssertTrue(JoystickInput.make(x: 0.1, y: 0, topSpeed: 10).isIdle, "inside the dead zone")
    }

    func testDirectionsAreCompassBearings() {
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: 10).heading, 0, accuracy: 1e-9)       // up = north
        XCTAssertEqual(JoystickInput.make(x: 1, y: 0, topSpeed: 10).heading, 90, accuracy: 1e-9)      // right = east
        XCTAssertEqual(JoystickInput.make(x: 0, y: -1, topSpeed: 10).heading, 180, accuracy: 1e-9)     // down = south
        XCTAssertEqual(JoystickInput.make(x: -1, y: 0, topSpeed: 10).heading, 270, accuracy: 1e-9)     // left = west
        XCTAssertEqual(JoystickInput.make(x: 0.7, y: 0.7, topSpeed: 10).heading, 45, accuracy: 0.01)
    }

    func testFullDeflectionIsTheTopSpeed() {
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: 14).speed, 14, accuracy: 1e-9)
        XCTAssertEqual(JoystickInput.make(x: 3, y: 4, topSpeed: 14).speed, 14, accuracy: 1e-9, "past the edge is held at full")
    }

    func testSpeedRisesWithDeflectionAndNeverPassesTheTop() {
        var last = 0.0
        for step in stride(from: 0.13, through: 1.0, by: 0.03) {
            let speed = JoystickInput.make(x: 0, y: step, topSpeed: 10).speed
            XCTAssertGreaterThanOrEqual(speed, last, "steps up as the thumb goes out (\(step))")
            XCTAssertLessThanOrEqual(speed, 10)
            last = speed
        }
        XCTAssertGreaterThan(JoystickInput.make(x: 0, y: 0.5, topSpeed: 10).speed, 0)
        XCTAssertLessThan(JoystickInput.make(x: 0, y: 0.5, topSpeed: 10).speed, 5, "half way is under half speed: gentle at first")
    }

    func testTheMapCanBeTurned() {
        // Map turned 90 degrees clockwise: "up on the screen" is east.
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: 5, mapHeading: 90, relativeToMap: true).heading, 90, accuracy: 1e-9)
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: 5, mapHeading: 300, relativeToMap: true).heading, 300, accuracy: 1e-9)
        XCTAssertEqual(JoystickInput.make(x: 1, y: 0, topSpeed: 5, mapHeading: 300, relativeToMap: true).heading, 30, accuracy: 1e-9)
        // Not relative to the map: the turn is ignored.
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: 5, mapHeading: 90, relativeToMap: false).heading, 0, accuracy: 1e-9)
    }

    func testTheTopSpeedIsHeldToWhatTheMacAccepts() {
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: 500).speed, JoystickInput.maxSpeed)
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: 0).speed, JoystickInput.minTopSpeed, accuracy: 1e-9)
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: -5).speed, JoystickInput.minTopSpeed, accuracy: 1e-9)
    }

    func testNonsenseInputIsIdleNotACrash() {
        for v in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(JoystickInput.make(x: v, y: 1, topSpeed: 5), .idle)
            XCTAssertEqual(JoystickInput.make(x: 1, y: v, topSpeed: 5), .idle)
            XCTAssertEqual(JoystickInput.make(x: 1, y: 1, topSpeed: v), .idle)
        }
        // A bad map heading is ignored rather than poisoning the heading.
        XCTAssertEqual(JoystickInput.make(x: 0, y: 1, topSpeed: 5, mapHeading: .nan, relativeToMap: true).heading, 0, accuracy: 1e-9)
    }

    func testTheHeadingIsAlwaysInRange() {
        for x in stride(from: -1.0, through: 1.0, by: 0.25) {
            for y in stride(from: -1.0, through: 1.0, by: 0.25) {
                for map in [0.0, 45, 359, 720, -90] {
                    let h = JoystickInput.make(x: x, y: y, topSpeed: 5, mapHeading: map, relativeToMap: true).heading
                    XCTAssertTrue(h >= 0 && h < 360, "\(x),\(y),\(map) -> \(h)")
                }
            }
        }
    }

    func testMovingAlongABearing() {
        let north = PhoneGeo.moved(latitude: 10, longitude: 20, meters: 111_195, bearing: 0)
        XCTAssertEqual(north.latitude, 11, accuracy: 0.002)
        XCTAssertEqual(north.longitude, 20, accuracy: 1e-6)
        let south = PhoneGeo.moved(latitude: 10, longitude: 20, meters: 111_195, bearing: 180)
        XCTAssertEqual(south.latitude, 9, accuracy: 0.002)
        let east = PhoneGeo.moved(latitude: 0, longitude: 0, meters: 111_195, bearing: 90)
        XCTAssertEqual(east.longitude, 1, accuracy: 0.002)
        XCTAssertEqual(east.latitude, 0, accuracy: 1e-6)
        let same = PhoneGeo.moved(latitude: 37.3, longitude: -122, meters: 0, bearing: 45)
        XCTAssertEqual(same.latitude, 37.3, accuracy: 1e-12)
        XCTAssertEqual(same.longitude, -122, accuracy: 1e-12)
    }

    func testMovingStaysOnTheMap() {
        XCTAssertEqual(PhoneGeo.moved(latitude: 84, longitude: 0, meters: 500_000, bearing: 0).latitude, 85, "held to the map")
        XCTAssertEqual(PhoneGeo.moved(latitude: -84, longitude: 0, meters: 500_000, bearing: 180).latitude, -85)
        XCTAssertEqual(PhoneGeo.moved(latitude: 90, longitude: 0, meters: 0, bearing: 0).latitude, 85, "even when not moving")
        let across = PhoneGeo.moved(latitude: 0, longitude: 179.9, meters: 50_000, bearing: 90)
        XCTAssertTrue((-180...180).contains(across.longitude), "wraps at the date line: \(across.longitude)")
        XCTAssertLessThan(across.longitude, -179)
        for v in [Double.nan, .infinity] {
            XCTAssertEqual(PhoneGeo.moved(latitude: v, longitude: 0, meters: 5, bearing: 0).latitude, 0)
            let ok = PhoneGeo.moved(latitude: 10, longitude: 10, meters: v, bearing: 0)
            XCTAssertEqual(ok.latitude, 10, accuracy: 1e-12)
            let b = PhoneGeo.moved(latitude: 10, longitude: 10, meters: 5, bearing: v)
            XCTAssertEqual(b.latitude, 10, accuracy: 1e-12)
        }
    }

    func testSpeedText() {
        XCTAssertEqual(SpeedText.format(metersPerSecond: 10, imperial: false), "36 km/h")
        XCTAssertEqual(SpeedText.format(metersPerSecond: 10, imperial: true), "22 mph")
        XCTAssertEqual(SpeedText.format(metersPerSecond: 1.4, imperial: false), "5 km/h")
        XCTAssertEqual(SpeedText.format(metersPerSecond: 0, imperial: false), "0 km/h")
        XCTAssertEqual(SpeedText.format(metersPerSecond: -3, imperial: true), "0 mph")
        XCTAssertEqual(SpeedText.format(metersPerSecond: .nan, imperial: false), "0 km/h")
        XCTAssertEqual(SpeedText.format(metersPerSecond: .infinity, imperial: false), "0 km/h")
        XCTAssertEqual(SpeedText.format(metersPerSecond: 1e300, imperial: false), "9999 km/h")
    }

    func testCompassPoints() {
        let expected: [(Double, String)] = [(0, "N"), (22, "N"), (23, "NE"), (45, "NE"), (90, "E"), (135, "SE"), (180, "S"),
                                            (225, "SW"), (270, "W"), (315, "NW"), (337, "NW"), (338, "N"), (359.9, "N"),
                                            (360, "N"), (-90, "W"), (720 + 90, "E")]
        for (heading, point) in expected {
            XCTAssertEqual(JoystickInput.compassPoint(heading), point, "\(heading)")
        }
        XCTAssertEqual(JoystickInput.compassPoint(.nan), "N")
    }

    func testPresetsGoFromSlowToFast() {
        let speeds = JoystickPreset.allCases.map(\.metersPerSecond)
        XCTAssertEqual(speeds, speeds.sorted())
        XCTAssertEqual(JoystickPreset.walk.metersPerSecond, 1.4)
        XCTAssertEqual(JoystickPreset.metersPerSecond(fromKmh: 36), 10, accuracy: 1e-9)
        XCTAssertEqual(JoystickPreset.kmh(fromMetersPerSecond: 10), 36, accuracy: 1e-9)
        for p in JoystickPreset.allCases { XCTAssertFalse(p.label.isEmpty); XCTAssertFalse(p.symbol.isEmpty) }
    }
}
