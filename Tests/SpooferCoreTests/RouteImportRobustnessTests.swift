import XCTest
@testable import SpooferCore

/// Files from real loggers are not always clean: no-fix samples written as
/// "nan", swapped columns, several trips in one file, a download cut short.
final class RouteImportRobustnessTests: XCTestCase {
    private func gpx(_ body: String, creator: String = "Logger") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(creator)" xmlns="http://www.topografix.com/GPX/1/1">\(body)</gpx>
        """.utf8)
    }

    private func trkpt(_ lat: String, _ lon: String, time: String? = nil) -> String {
        time.map { #"<trkpt lat="\#(lat)" lon="\#(lon)"><time>\#($0)</time></trkpt>"# } ?? #"<trkpt lat="\#(lat)" lon="\#(lon)"/>"#
    }

    // MARK: Positions that are not real places

    func testNaNInfiniteAndOutOfRangeFixesAreLeftOut() throws {
        let data = gpx("""
        <trk><trkseg>
          \(trkpt("37.3300", "-122.0000", time: "2024-05-01T08:00:00Z"))
          \(trkpt("nan", "-122.0010", time: "2024-05-01T08:00:01Z"))
          \(trkpt("37.3310", "inf", time: "2024-05-01T08:00:02Z"))
          \(trkpt("1e999", "-122.0020"))
          \(trkpt("37.3320", "-122.0030", time: "2024-05-01T08:00:04Z"))
          \(trkpt("95", "10"))
          \(trkpt("-122.5", "37.3"))
          \(trkpt("0", "400"))
          \(trkpt("37.3340", "-122.0040", time: "2024-05-01T08:00:06Z"))
        </trkseg></trk>
        """)
        let route = try RouteImporter.parse(data)
        XCTAssertEqual(route.points, [GeoPoint(37.33, -122.0), GeoPoint(37.332, -122.003), GeoPoint(37.334, -122.004)])
        XCTAssertEqual(route.skippedPoints, 6)
        XCTAssertTrue(route.points.allSatisfy(\.isValid))
        XCTAssertEqual(route.duration ?? 0, 6, accuracy: 1e-6)
        XCTAssertEqual(route.warning, "Left out 6 positions that are not real places.")
        // A route built from it can be matched and simplified without trouble.
        let path = RoutePath(route.points)
        XCTAssertTrue(path.length.isFinite)
        XCTAssertLessThan(path.length, 1000)
        _ = RouteMatcher(path: path)
    }

    func testWaypointAndRouteFilesAreChecked() throws {
        let rte = gpx(#"<rte><rtept lat="1" lon="2"/><rtept lat="nan" lon="3"/><rtept lat="5" lon="6"/></rte>"#)
        let route = try RouteImporter.parse(rte)
        XCTAssertEqual(route.points, [GeoPoint(1, 2), GeoPoint(5, 6)])
        XCTAssertEqual(route.skippedPoints, 1)
        XCTAssertTrue(route.isWaypointList)

        let wpt = gpx(#"<wpt lat="inf" lon="2"/><wpt lat="10" lon="20"/>"#)
        XCTAssertEqual(try RouteImporter.parse(wpt).points, [GeoPoint(10, 20)])
    }

    func testAFileWithOnlyBadPositionsIsRefused() {
        let data = gpx(#"<trk><trkseg>\#(trkpt("nan", "nan"))\#(trkpt("95", "0"))</trkseg></trk>"#)
        XCTAssertThrowsError(try RouteImporter.parse(data)) { error in
            XCTAssertTrue("\(error)".contains("no usable positions"), "\(error)")
        }
    }

    func testKMLCoordinatesAreChecked() throws {
        let line = """
        <kml><Document><Placemark><LineString><coordinates>
          2.2945,48.8584,0 nan,48.8600,0 2.3100,48.8650,0 2.32,inf,0 200.5,10,0 abc,5,0 2.3300,48.8700
        </coordinates></LineString></Placemark></Document></kml>
        """
        let route = try RouteImporter.parse(Data(line.utf8))
        XCTAssertEqual(route.points, [GeoPoint(48.8584, 2.2945), GeoPoint(48.865, 2.31), GeoPoint(48.87, 2.33)])
        XCTAssertEqual(route.skippedPoints, 4)

        let track = """
        <kml xmlns:gx="http://www.google.com/kml/ext/2.2"><Document><Placemark><gx:Track>
          <gx:coord>2.2945 48.8584 0</gx:coord><gx:coord>nan 48.86 0</gx:coord>
          <gx:coord>2.31 48.865 0</gx:coord><gx:coord>2.32 -91 0</gx:coord>
        </gx:Track></Placemark></Document></kml>
        """
        let parsed = try RouteImporter.parse(Data(track.utf8))
        XCTAssertEqual(parsed.points, [GeoPoint(48.8584, 2.2945), GeoPoint(48.865, 2.31)])
        XCTAssertEqual(parsed.skippedPoints, 2)

        let place = #"<kml><Placemark><Point><coordinates>nan,nan</coordinates></Point></Placemark></kml>"#
        XCTAssertThrowsError(try RouteImporter.parse(Data(place.utf8)))
    }

    func testOneBadFixDoesNotCollapseALongTrack() throws {
        // A winding 500-point track, with and without a no-fix sample in the middle.
        let points = (0..<500).map { i in
            GeoPoint(37.0 + Double(i) * 0.0002, -122.0 + sin(Double(i) / 12) * 0.003)
        }
        func file(withBadFix: Bool) -> Data {
            var rows = points.map { trkpt("\($0.latitude)", "\($0.longitude)") }
            if withBadFix { rows.insert(trkpt("nan", "-122.0"), at: 250) }
            return gpx("<trk><trkseg>\(rows.joined())</trkseg></trk>")
        }
        let clean = try RouteImporter.parse(file(withBadFix: false))
        let dirty = try RouteImporter.parse(file(withBadFix: true))
        XCTAssertEqual(dirty.points, clean.points)
        let simplified = RouteSimplifier.simplify(dirty.points, maxPoints: 200)
        XCTAssertGreaterThan(simplified.count, 20)
        XCTAssertEqual(simplified, RouteSimplifier.simplify(clean.points, maxPoints: 200))
    }

    // MARK: Several trips in one file

    private let sydney = GeoPoint(-33.8688, 151.2093)
    private let paris = GeoPoint(48.8566, 2.3522)

    private func points(from start: GeoPoint, count: Int, step: Double) -> [GeoPoint] {
        (0..<count).map { start.moved(by: Double($0) * step, bearing: 45) }
    }

    private func track(_ points: [GeoPoint]) -> String {
        "<trk><trkseg>" + points.map { trkpt("\($0.latitude)", "\($0.longitude)") }.joined() + "</trkseg></trk>"
    }

    func testTwoTripsFarApartAreNotJoinedByAStraightLine() throws {
        let short = points(from: sydney, count: 4, step: 200)     // 600 m
        let long = points(from: paris, count: 6, step: 300)        // 1.5 km
        let route = try RouteImporter.parse(gpx(track(short) + track(long)))
        XCTAssertEqual(route.points, long)
        XCTAssertEqual(route.skippedSegments, 1)
        XCTAssertEqual(route.length, 1500, accuracy: 5)
        XCTAssertEqual(route.warning, "The file has another stretch far away from this one. Only the longest was used.")
    }

    func testPausesWithinAKilometreStayOneRoute() throws {
        let first = points(from: paris, count: 5, step: 100)
        let second = points(from: first.last!.moved(by: 300, bearing: 45), count: 5, step: 100)   // resumed 300 m on
        let route = try RouteImporter.parse(gpx(track(first) + track(second)))
        XCTAssertEqual(route.points, first + second)
        XCTAssertEqual(route.skippedSegments, 0)
        XCTAssertNil(route.warning)
    }

    func testKMLRouteNextToAnOutlineIsJustTheRoute() throws {
        let kml = """
        <kml><Document>
          <Placemark><name>Route</name><LineString><coordinates>2.2945,48.8584,0 2.3000,48.8600,0 2.3100,48.8650,0</coordinates></LineString></Placemark>
          <Placemark><name>Park</name><Polygon><outerBoundaryIs><LinearRing><coordinates>
            -122.0,37.0,0 -122.1,37.0,0 -122.1,37.1,0 -122.0,37.1,0 -122.0,37.0,0
          </coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
        </Document></kml>
        """
        let route = try RouteImporter.parse(Data(kml.utf8))
        XCTAssertEqual(route.points, [GeoPoint(48.8584, 2.2945), GeoPoint(48.86, 2.3), GeoPoint(48.865, 2.31)])
        XCTAssertLessThan(route.length, 3000)
        XCTAssertFalse(route.isWaypointList)
    }

    func testKMLOutlineAloneStillImports() throws {
        let kml = """
        <kml><Placemark><Polygon><outerBoundaryIs><LinearRing><coordinates>
          -122.0,37.0,0 -122.01,37.0,0 -122.01,37.01,0 -122.0,37.0,0
        </coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark></kml>
        """
        XCTAssertEqual(try RouteImporter.parse(Data(kml.utf8)).points.count, 4)
    }

    func testKMLLinesFarApartKeepTheLongest() throws {
        func line(_ ps: [GeoPoint]) -> String {
            "<Placemark><LineString><coordinates>" + ps.map { "\($0.longitude),\($0.latitude),0" }.joined(separator: " ")
                + "</coordinates></LineString></Placemark>"
        }
        let short = points(from: sydney, count: 3, step: 100)
        let long = points(from: paris, count: 5, step: 400)
        let route = try RouteImporter.parse(Data("<kml><Document>\(line(short))\(line(long))</Document></kml>".utf8))
        XCTAssertEqual(route.points.count, 5)
        XCTAssertEqual(route.skippedSegments, 1)
        XCTAssertEqual(route.length, 1600, accuracy: 5)
    }

    func testOwnExportStillPrefersItsWaypointsUnderBothNames() throws {
        let waypoints = [GeoPoint(48.8584, 2.2945), GeoPoint(48.8606, 2.3376)]
        let track = [waypoints[0], GeoPoint(48.859, 2.31), GeoPoint(48.8601, 2.33), waypoints[1]]
        let xml = RouteBuilder.exportGPX(name: "Loop", waypoints: waypoints, track: track)
        XCTAssertTrue(xml.contains(#"creator="AnyWhere""#))
        XCTAssertEqual(try RouteImporter.parse(Data(xml.utf8)).points, waypoints)
        // A file made by an earlier build says the old name.
        let old = xml.replacingOccurrences(of: #"creator="AnyWhere""#, with: #"creator="iosgpsspoof""#)
        let back = try RouteImporter.parse(Data(old.utf8))
        XCTAssertEqual(back.points, waypoints)
        XCTAssertTrue(back.isWaypointList)
        // Anyone else's file keeps its recorded track.
        let other = xml.replacingOccurrences(of: #"creator="AnyWhere""#, with: #"creator="Strava""#)
        XCTAssertEqual(try RouteImporter.parse(Data(other.utf8)).points, track)
    }

    // MARK: Damaged files

    func testAFileCutOffMidwayIsRefused() {
        var rows = (0..<50).map { trkpt("\(37 + Double($0) * 0.001)", "-122") }.joined()
        rows += #"<trkpt lat="37.06" lo"#
        let text = #"<?xml version="1.0"?><gpx version="1.1" creator="Logger"><trk><trkseg>"# + rows
        XCTAssertThrowsError(try RouteImporter.parse(Data(text.utf8))) { error in
            XCTAssertTrue("\(error)".contains("cut off or damaged"), "\(error)")
        }
        // Cut off cleanly between two points, with the closing tags missing.
        let clean = #"<?xml version="1.0"?><gpx><trk><trkseg>"# + (0..<10).map { trkpt("\(1 + Double($0))", "1") }.joined()
        XCTAssertThrowsError(try RouteImporter.parse(Data(clean.utf8)))
    }

    func testAMistakeInTheMiddleOfAFileIsRefused() {
        // A bare ampersand in a waypoint's name is not valid XML.
        let text = gpx("<trk><trkseg>\(trkpt("1", "1"))\(trkpt("2", "2"))</trkseg></trk><wpt lat=\"3\" lon=\"3\"><name>Tom & Jerry</name></wpt>")
        XCTAssertThrowsError(try RouteImporter.parse(text))
    }

    func testJunkAfterTheClosingTagIsHarmless() throws {
        var data = gpx("<trk><trkseg>\(trkpt("1", "1"))\(trkpt("2", "2"))</trkseg></trk>")
        data.append(Data("\n\u{0}\u{0}garbage after the end".utf8))
        XCTAssertEqual(try RouteImporter.parse(data).points.count, 2)
    }

    func testKMLCoordinatesWithSpacesAfterTheCommas() throws {
        let kml = """
        <kml><Placemark><LineString><coordinates>
          2.2945, 48.8584, 0 2.3000 , 48.8600 , 0
          2.3100,48.8650
        </coordinates></LineString></Placemark></kml>
        """
        let route = try RouteImporter.parse(Data(kml.utf8))
        XCTAssertEqual(route.points, [GeoPoint(48.8584, 2.2945), GeoPoint(48.86, 2.3), GeoPoint(48.865, 2.31)])
        XCTAssertEqual(route.skippedPoints, 0)

        // A stray comma after a whole tuple doesn't join it to the next one.
        let stray = #"<kml><Placemark><LineString><coordinates>2.29,48.85,0, 2.30,48.86,0, 2.31,48.87,0,</coordinates></LineString></Placemark></kml>"#
        XCTAssertEqual(try RouteImporter.parse(Data(stray.utf8)).points,
                       [GeoPoint(48.85, 2.29), GeoPoint(48.86, 2.3), GeoPoint(48.87, 2.31)])
    }

    // MARK: Times

    func testTimeStampsAreReadByHand() {
        let table: [(String, Double?)] = [
            ("2024-05-01T08:00:00Z", 1_714_550_400),
            ("2024-05-01T08:00:00.500Z", 1_714_550_400.5),
            ("2024-05-01T08:00:00.5Z", 1_714_550_400.5),
            ("2024-05-01T10:00:00+02:00", 1_714_550_400),
            ("2024-05-01T02:30:00-0530", 1_714_550_400),
            ("2024-02-29T23:59:59Z", 1_709_251_199),
            ("1969-12-31T23:59:59Z", -1),
            ("2000-01-01T00:00:00Z", 946_684_800),
            ("2100-03-01T00:00:00Z", 4_107_542_400),
            ("2023-11-14T22:13:20Z", 1_700_000_000),
            ("2023-02-29T00:00:00Z", nil),
            ("2024-13-01T00:00:00Z", nil),
            ("2024-05-01T24:00:00Z", nil),
            ("2024-05-01T08:00:00", nil),
            ("2024-05-01 08:00:00Z", nil),
            ("2024-05-01T08:00:00.Z", nil),
            ("2024-05-01T08:00:00Zjunk", nil),
            ("yesterday", nil),
            ("", nil),
        ]
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (text, expected) in table {
            let mine = GPXTime.date(from: text)?.timeIntervalSince1970
            if let expected {
                XCTAssertEqual(mine ?? .nan, expected, accuracy: 1e-6, text)
                // Wherever both read a stamp, they agree.
                if let theirs = (isoFractional.date(from: text) ?? iso.date(from: text))?.timeIntervalSince1970 {
                    XCTAssertEqual(mine ?? .nan, theirs, accuracy: 1e-3, text)
                }
            } else {
                XCTAssertNil(mine, text)
            }
        }
    }

    func testSloppyStampsThatFoundationReadsStillCount() throws {
        // Not strict ISO 8601, but this is how they have always been read.
        let data = gpx("<trk><trkseg>"
            + trkpt("1", "1", time: "2024-5-1T8:0:0Z") + trkpt("1.001", "1", time: "2024-05-01T08:00:10Z ")
            + trkpt("1.002", "1", time: "2024-05-01T08:00:20Zjunk") + "</trkseg></trk>")
        let route = try RouteImporter.parse(data)
        XCTAssertEqual(route.duration ?? 0, 20, accuracy: 1e-6)
        // A file whose stamps cannot be read at all just has no timing.
        let unreadable = (0..<200).map { trkpt("1", "\(1 + Double($0) * 0.001)", time: "sometime") }.joined()
        let plain = try RouteImporter.parse(gpx("<trk><trkseg>\(unreadable)</trkseg></trk>"))
        XCTAssertEqual(plain.points.count, 200)
        XCTAssertNil(plain.duration)
    }

    func testALongRecordingWithTimesImportsQuickly() throws {
        let count = 30_000
        var rows = ""
        rows.reserveCapacity(count * 90)
        for i in 0..<count {
            let seconds = i
            let time = String(format: "2024-05-01T%02ld:%02ld:%02ldZ", 8 + seconds / 3600, seconds / 60 % 60, seconds % 60)
            rows += trkpt("\(37 + Double(i) * 0.00001)", "-122.0", time: time)
        }
        let route = try RouteImporter.parse(gpx("<trk><trkseg>\(rows)</trkseg></trk>"))
        XCTAssertEqual(route.points.count, count)
        XCTAssertEqual(route.duration ?? 0, Double(count - 1), accuracy: 1e-6)
    }
}
