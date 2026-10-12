import Foundation
import XCTest
@testable import PhoneOnlyCore

final class CoordinateTextTests: XCTestCase {
    private func point(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> CoordinateText.Point? {
        CoordinateText.parse(text)
    }

    private func assertPoint(_ text: String, _ latitude: Double, _ longitude: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let found = point(text) else {
            return XCTFail("\"\(text)\" should be coordinates", file: file, line: line)
        }
        XCTAssertEqual(found.latitude, latitude, accuracy: 1e-9, "latitude of \"\(text)\"", file: file, line: line)
        XCTAssertEqual(found.longitude, longitude, accuracy: 1e-9, "longitude of \"\(text)\"", file: file, line: line)
    }

    func testTheUsualForms() {
        assertPoint("37.3349, -122.0090", 37.3349, -122.0090)
        assertPoint("37.3349,-122.0090", 37.3349, -122.0090)
        assertPoint("37.3349 -122.0090", 37.3349, -122.0090)
        assertPoint("  48.8584 ,  2.2945  ", 48.8584, 2.2945)
        assertPoint("-33.8688; 151.2093", -33.8688, 151.2093)
        assertPoint("0, 0", 0, 0)
        assertPoint("90 180", 90, 180)
        assertPoint("-90, -180", -90, -180)
    }

    /// Apple Maps and Google Maps copy coordinates with brackets and degree signs.
    func testBracketsAndDegreeSigns() {
        assertPoint("(37.3349, -122.0090)", 37.3349, -122.0090)
        assertPoint("[37.3349, -122.0090]", 37.3349, -122.0090)
        assertPoint("37.3349°, -122.0090°", 37.3349, -122.0090)
    }

    func testHemisphereLetters() {
        assertPoint("37.3349° N, 122.0090° W", 37.3349, -122.0090)
        assertPoint("37.3349N 122.0090W", 37.3349, -122.0090)
        assertPoint("33.8688 S, 151.2093 E", -33.8688, 151.2093)
        assertPoint("N 37.3349 W 122.0090", 37.3349, -122.0090)
        assertPoint("n37.3349, w122.0090", 37.3349, -122.0090)
    }

    func testDecimalComma() {
        assertPoint("37,3349 -122,0090", 37.3349, -122.0090)
        assertPoint("48,8584 2,2945", 48.8584, 2.2945)
    }

    /// The old reader dropped every word and kept the numbers, so an address
    /// with two small numbers became a "Go to these coordinates" row.
    func testAddressesWithTwoSmallNumbersAreNotCoordinates() {
        XCTAssertNil(point("Pier 39 San Francisco 37"))
        XCTAssertNil(point("Terminal 1 Gate 5"))
        XCTAssertNil(point("Hwy 1 mile 12"))
        XCTAssertNil(point("Apple Park 1"))
        XCTAssertNil(point("1 Infinite Loop 95014"))
        XCTAssertNil(point("Gate 5, Terminal 2"))
    }

    func testOutOfRangeIsNotACoordinate() {
        XCTAssertNil(point("91, 10"))
        XCTAssertNil(point("-91, 10"))
        XCTAssertNil(point("10, 181"))
        XCTAssertNil(point("10, -181"))
        XCTAssertNil(point("37 3349"))
    }

    func testWrongCountIsNotACoordinate() {
        XCTAssertNil(point(""))
        XCTAssertNil(point("37.3349"))
        XCTAssertNil(point("1, 2, 3"))
        XCTAssertNil(point("37.3349, -122.0090, 12"))
    }

    func testLettersMustMakeSense() {
        XCTAssertNil(point("37.3349 E, 122.0090 N"))      // east for a latitude
        XCTAssertNil(point("37.3349 N, 122.0090"))        // a letter on one number only
        XCTAssertNil(point("-37.3349 S, 122.0090 E"))     // a sign and a letter both
        XCTAssertNil(point("N 37.3349 W"))                // a letter left over
        XCTAssertNil(point("N N 37.3349 W 122.0090"))
        XCTAssertNil(point("37.3349 Q 122.0090"))
    }

    /// `Double()` also reads hex, exponents and "inf", none of which are coordinates.
    func testOnlyPlainNumbersAreRead() {
        XCTAssertNil(point("0x10 0x20"))
        XCTAssertNil(point("1e1 2e1"))
        XCTAssertNil(point("inf 10"))
        XCTAssertNil(point("nan 10"))
        XCTAssertNil(point("1.2.3 4"))
        XCTAssertNil(point("- 5"))
        XCTAssertNil(point("1-2 3"))
    }

    func testFullWidthDigitsAreNotRead() {
        XCTAssertNil(point("３７ １２２"))
    }
}
