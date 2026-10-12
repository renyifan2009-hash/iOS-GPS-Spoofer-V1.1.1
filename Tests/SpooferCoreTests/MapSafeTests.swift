import XCTest
@testable import SpooferCore

/// Following the device to a pole once crashed the app: MapKit raised "Invalid Coordinate" from
/// setCenter. The rule that keeps the camera inside the map's world lives here, where it can be tested.
final class MapSafeTests: XCTestCase {
    func testPolesAreHeldInsideTheMapsWorld() {
        XCTAssertEqual(GeoPoint(90, 0).mapSafe, GeoPoint(85, 0))
        XCTAssertEqual(GeoPoint(-90, 120).mapSafe, GeoPoint(-85, 120))
        XCTAssertEqual(GeoPoint(89.5, -45).mapSafe, GeoPoint(85, -45))
    }

    func testOrdinaryPlacesAreUnchanged() {
        for p in [GeoPoint(37.3349, -122.009), GeoPoint(0, 0), GeoPoint(-33.86, 151.21), GeoPoint(84.9, 180), GeoPoint(-85, -180)] {
            XCTAssertEqual(p.mapSafe, p)
        }
    }

    func testAnythingThatIsNotAPlaceIsRefused() {
        let bad = [GeoPoint(.nan, 0), GeoPoint(0, .nan), GeoPoint(.infinity, 0), GeoPoint(0, -.infinity),
                   GeoPoint(91, 0), GeoPoint(0, 181), GeoPoint(37_334_900, -122), GeoPoint(1e300, 1e300)]
        for p in bad { XCTAssertNil(p.mapSafe, "\(p)") }
    }

    func testTheClampedPointIsAlwaysValid() {
        for lat in stride(from: -90.0, through: 90.0, by: 7.5) {
            for lon in stride(from: -180.0, through: 180.0, by: 45) {
                let safe = GeoPoint(lat, lon).mapSafe
                XCTAssertNotNil(safe)
                XCTAssertTrue(safe?.isValid ?? false)
                XCTAssertLessThanOrEqual(abs(safe?.latitude ?? 0), GeoPoint.mapMaxLatitude)
            }
        }
    }
}
