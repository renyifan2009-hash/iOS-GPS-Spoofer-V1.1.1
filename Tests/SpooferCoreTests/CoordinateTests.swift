import XCTest
@testable import SpooferCore

final class CoordinateTests: XCTestCase {
    private func assertParses(_ text: String, _ lat: Double, _ lon: Double, accuracy: Double = 1e-6,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let p = Coordinate.parsePoint(text) else {
            return XCTFail("could not parse: \(text)", file: file, line: line)
        }
        XCTAssertEqual(p.latitude, lat, accuracy: accuracy, "latitude of \(text)", file: file, line: line)
        XCTAssertEqual(p.longitude, lon, accuracy: accuracy, "longitude of \(text)", file: file, line: line)
    }

    func testDecimalPairs() {
        assertParses("48.8584, 2.2945", 48.8584, 2.2945)
        assertParses("48.8584 2.2945", 48.8584, 2.2945)
        assertParses("48.8584,2.2945", 48.8584, 2.2945)
        assertParses("(48.8584; 2.2945)", 48.8584, 2.2945)
        assertParses("  -33.8568 , 151.2153  ", -33.8568, 151.2153)
        assertParses("40.758\t-73.9855", 40.758, -73.9855)
    }

    func testDegreesMinutesSeconds() {
        assertParses(#"48°51'30"N 2°17'40"E"#, 48.858333, 2.294444)
        assertParses("48°51′30″N, 2°17′40″E", 48.858333, 2.294444)
        assertParses(#"33°51'54"S 151°12'55"E"#, -33.865, 151.215278)
        assertParses("N 48° 51.5' E 2° 17.666'", 48.858333, 2.294433)
        assertParses("48.8584° N, 2.2945° E", 48.8584, 2.2945)
        assertParses("40 41 21 N 74 2 40 W", 40.689167, -74.044444)
        assertParses(#"2°17'40"E 48°51'30"N"#, 48.858333, 2.294444)   // longitude first
        assertParses("48 deg 51 min 30 sec N, 2 deg 17 min 40 sec E", 48.858333, 2.294444)
    }

    func testMapLinks() {
        assertParses("https://www.google.com/maps/place/Eiffel+Tower/@48.8583701,2.2919064,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d48.8583701!4d2.2944813",
                     48.8583701, 2.2944813)
        assertParses("https://www.google.com/maps/@40.6892,-74.0445,15z", 40.6892, -74.0445)
        assertParses("https://maps.google.com/?q=35.6595,139.7005", 35.6595, 139.7005)
        assertParses("https://www.google.com/maps/search/?api=1&query=41.8902%2C12.4922", 41.8902, 12.4922)
        assertParses("https://maps.apple.com/?ll=37.3349,-122.009&q=Apple%20Park", 37.3349, -122.009)
        assertParses("https://maps.apple.com/place?coordinate=51.5007,-0.1246&name=Big%20Ben", 51.5007, -0.1246)
        assertParses("https://www.openstreetmap.org/?mlat=52.5163&mlon=13.3777#map=17/52.5163/13.3777", 52.5163, 13.3777)
        assertParses("https://www.openstreetmap.org/#map=17/41.8902/12.4922", 41.8902, 12.4922)
        assertParses("https://www.bing.com/maps?cp=48.8584~2.2945&lvl=17", 48.8584, 2.2945)
        assertParses("geo:48.8584,2.2945", 48.8584, 2.2945)
        assertParses("geo:48.8584,2.2945;u=35", 48.8584, 2.2945)
        assertParses("geo:0,0?q=48.8584,2.2945(Eiffel%20Tower)", 48.8584, 2.2945)
    }

    func testRejectsGarbage() {
        for text in ["", "hello", "1 2 3", "N 1 N 2", "48°61'00\"N 2°00'00\"E", "https://example.com/nothing", "12"] {
            XCTAssertNil(Coordinate.parsePoint(text), "should not parse: \(text)")
        }
    }

    func testTupleAPIStillWorks() {
        let parsed = Coordinate.parse("48.8584,2.2945")
        XCTAssertEqual(parsed?.latitude ?? 0, 48.8584, accuracy: 1e-9)
        XCTAssertEqual(parsed?.longitude ?? 0, 2.2945, accuracy: 1e-9)
    }

    func testValidation() {
        XCTAssertNoThrow(try Coordinate.validate(latitude: 90, longitude: -180))
        XCTAssertThrowsError(try Coordinate.validate(latitude: 90.1, longitude: 0))
        XCTAssertThrowsError(try Coordinate.validate(latitude: 0, longitude: 180.5))
        XCTAssertThrowsError(try Coordinate.validate(latitude: .nan, longitude: 0))
        XCTAssertFalse(GeoPoint(91, 0).isValid)
        XCTAssertTrue(GeoPoint(-90, 180).isValid)
    }

    func testFormatting() {
        XCTAssertEqual(Coordinate.format(GeoPoint(48.8584, 2.2945), precision: 4), "48.8584, 2.2945")
        XCTAssertEqual(Coordinate.formatDMS(GeoPoint(48.858333, 2.294444)), "48°51′30.0″N 2°17′40.0″E")
        XCTAssertEqual(Coordinate.formatDMS(GeoPoint(-33.865, 151.215278)), "33°51′54.0″S 151°12′55.0″E")
        // Round trip through the DMS parser.
        let original = GeoPoint(-22.951_9, -43.210_5)
        let reparsed = Coordinate.parsePoint(Coordinate.formatDMS(original))
        XCTAssertEqual(reparsed?.latitude ?? 0, original.latitude, accuracy: 1e-4)
        XCTAssertEqual(reparsed?.longitude ?? 0, original.longitude, accuracy: 1e-4)
    }
}
