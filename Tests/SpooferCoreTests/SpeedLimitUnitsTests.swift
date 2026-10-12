import XCTest
@testable import SpooferCore

/// Units in OpenStreetMap's `maxspeed` tag.
final class SpeedLimitUnitsTests: XCTestCase {
    func testMaxspeedInKnots() {
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "30 knots") ?? 0, 30 * 0.514444, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.speed(tags: ["highway": "residential", "maxspeed": "10 knots"]) ?? 0,
                       10 * 0.514444, accuracy: 1e-9)
        // And the units next to it did not change.
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "30 mph") ?? 0, 30 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "30") ?? 0, 30 / 3.6, accuracy: 1e-9)
        XCTAssertNil(SpeedLimits.parse(maxspeed: "0"))
        XCTAssertNil(SpeedLimits.parse(maxspeed: "999"))
    }
}
