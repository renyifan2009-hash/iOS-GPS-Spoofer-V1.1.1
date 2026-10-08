import XCTest
@testable import SpooferCore

final class RouteImporterTests: XCTestCase {
    func testGPXTrackWithTimes() throws {
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="Strava" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>Morning Walk</name><trkseg>
            <trkpt lat="48.8584" lon="2.2945"><ele>35</ele><time>2024-05-01T08:00:00Z</time></trkpt>
            <trkpt lat="48.8590" lon="2.2950"><time>2024-05-01T08:00:10Z</time></trkpt>
            <trkpt lat="48.8600" lon="2.2960"><time>2024-05-01T08:00:20.500Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let route = try RouteImporter.parse(Data(xml.utf8))
        XCTAssertEqual(route.name, "Morning Walk")
        XCTAssertEqual(route.points.count, 3)
        XCTAssertFalse(route.isWaypointList)
        XCTAssertEqual(route.points[1], GeoPoint(48.8590, 2.2950))
        XCTAssertEqual(route.duration ?? 0, 20.5, accuracy: 1e-6)
        XCTAssertEqual(route.averageSpeed ?? 0, route.length / 20.5, accuracy: 1e-9)
    }

    func testGPXRouteAndWaypoints() throws {
        let rte = """
        <gpx><rte><name>Errands</name>
          <rtept lat="1" lon="2"/><rtept lat="3" lon="4"/><rtept lat="5" lon="6"/>
        </rte></gpx>
        """
        let route = try RouteImporter.parse(Data(rte.utf8))
        XCTAssertTrue(route.isWaypointList)
        XCTAssertEqual(route.points, [GeoPoint(1, 2), GeoPoint(3, 4), GeoPoint(5, 6)])
        XCTAssertNil(route.duration)

        let wpt = #"<gpx><wpt lat="-33.8568" lon="151.2153"><name>Opera House</name></wpt></gpx>"#
        let place = try RouteImporter.parse(Data(wpt.utf8))
        XCTAssertEqual(place.points, [GeoPoint(-33.8568, 151.2153)])
        XCTAssertTrue(place.isWaypointList)
    }

    func testKML() throws {
        let line = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Drive</name>
          <Placemark><LineString><coordinates>
            2.2945,48.8584,0 2.3000,48.8600,0
            2.3100,48.8650,0
          </coordinates></LineString></Placemark>
        </Document></kml>
        """
        let route = try RouteImporter.parse(Data(line.utf8))
        XCTAssertEqual(route.name, "Drive")
        XCTAssertEqual(route.points, [GeoPoint(48.8584, 2.2945), GeoPoint(48.86, 2.3), GeoPoint(48.865, 2.31)])
        XCTAssertFalse(route.isWaypointList)

        let points = """
        <kml><Document>
          <Placemark><name>A</name><Point><coordinates>13.3777,52.5163</coordinates></Point></Placemark>
          <Placemark><name>B</name><Point><coordinates>12.4922,41.8902,10</coordinates></Point></Placemark>
        </Document></kml>
        """
        let placemarks = try RouteImporter.parse(Data(points.utf8))
        XCTAssertEqual(placemarks.points, [GeoPoint(52.5163, 13.3777), GeoPoint(41.8902, 12.4922)])
        XCTAssertTrue(placemarks.isWaypointList)
    }

    func testRejectsFilesWithoutPoints() {
        XCTAssertThrowsError(try RouteImporter.parse(Data("<gpx></gpx>".utf8)))
        XCTAssertThrowsError(try RouteImporter.parse(Data("not xml at all".utf8)))
    }

    func testExportRoundTripPrefersEditableWaypoints() throws {
        let waypoints = [GeoPoint(48.8584, 2.2945), GeoPoint(48.8606, 2.3376)]
        let track = [waypoints[0], GeoPoint(48.859, 2.31), GeoPoint(48.8601, 2.33), waypoints[1]]
        let xml = RouteBuilder.exportGPX(name: "Seine & Louvre", waypoints: waypoints, track: track)
        let back = try RouteImporter.parse(Data(xml.utf8))
        XCTAssertEqual(back.points, waypoints)
        XCTAssertTrue(back.isWaypointList)
        XCTAssertEqual(back.name, "Seine & Louvre")
    }

    func testLoadUsesFileNameWhenUnnamed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Commute-\(UUID().uuidString).gpx")
        try #"<gpx><trk><trkseg><trkpt lat="1" lon="1"/><trkpt lat="2" lon="2"/></trkseg></trk></gpx>"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let route = try RouteImporter.load(contentsOf: url)
        XCTAssertTrue(route.name?.hasPrefix("Commute-") ?? false)
    }
}

final class LibraryTests: XCTestCase {
    func testRecentsDeduplicateAndCap() {
        var library = LibraryData()
        library.recordRecent(SavedPlace(name: "A", point: GeoPoint(10, 10)))
        library.recordRecent(SavedPlace(name: "A again", point: GeoPoint(10.0001, 10)))   // ~11 m away
        XCTAssertEqual(library.recents.count, 1)
        XCTAssertEqual(library.recents.first?.name, "A again")
        for i in 0..<40 { library.recordRecent(SavedPlace(name: "\(i)", point: GeoPoint(Double(i), 50))) }
        XCTAssertEqual(library.recents.count, LibraryData.maxRecents)
        XCTAssertEqual(library.recents.first?.name, "39")
    }

    func testFavoriteLookup() {
        let library = LibraryData(favorites: [
            SavedPlace(name: "Home", point: GeoPoint(1, 1)),
            SavedPlace(name: "Homestead", point: GeoPoint(2, 2)),
            SavedPlace(name: "Work", point: GeoPoint(3, 3)),
        ])
        XCTAssertEqual(library.favorite(named: "home")?.point, GeoPoint(1, 1))
        XCTAssertEqual(library.favorite(named: "wo")?.name, "Work")
        XCTAssertNil(library.favorite(named: "gym"))
        XCTAssertNotNil(library.favorite(near: GeoPoint(1.00005, 1)))
        XCTAssertNil(library.favorite(near: GeoPoint(1.01, 1)))
    }

    func testSaveLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-\(UUID().uuidString)/library.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var library = LibraryData()
        library.favorites = [SavedPlace(name: "Eiffel", point: GeoPoint(48.8584, 2.2945))]
        library.routes = [SavedRoute(name: "Loop", waypoints: [GeoPoint(1, 1), GeoPoint(2, 2)],
                                     followRoads: true, travelMode: .driving, loopMode: .pingPong, speed: 13.9)]
        try LibraryFile.save(library, to: url)
        let loaded = LibraryFile.load(from: url)
        XCTAssertEqual(loaded.favorites.map(\.name), ["Eiffel"])
        XCTAssertEqual(loaded.routes.first?.loopMode, .pingPong)
        XCTAssertEqual(loaded.routes.first?.travelMode, .driving)
        XCTAssertEqual(loaded.routes.first?.waypoints.count, 2)
    }

    func testCorruptFileIsMovedAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        try Data("{ this is not json".utf8).write(to: url)
        let loaded = LibraryFile.load(from: url)
        XCTAssertEqual(loaded, LibraryData())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(leftovers.contains { $0.contains("corrupt") })
    }

    func testLenientRouteDecoding() throws {
        let json = #"{"name":"Old","waypoints":[{"latitude":1,"longitude":2}]}"#
        let route = try JSONDecoder().decode(SavedRoute.self, from: Data(json.utf8))
        XCTAssertEqual(route.name, "Old")
        XCTAssertEqual(route.loopMode, .once)
        XCTAssertEqual(route.waypoints, [GeoPoint(1, 2)])
    }
}

final class MiscTests: XCTestCase {
    func testDeviceDecodingAndModels() throws {
        let json = """
        [{"BuildVersion":"23F79","ConnectionType":"USB","DeviceClass":"iPhone","DeviceName":"Ava's iPhone",
          "Identifier":"00008110-0011304A1E61801E","ProductType":"iPhone14,3","ProductVersion":"26.5.2"},
         {"Identifier":"abc","ConnectionType":"Network","ProductVersion":"16.7.10","ProductType":"iPhone10,3"},
         {"Identifier":"def"}]
        """
        let devices = try JSONDecoder().decode([Device].self, from: Data(json.utf8))
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].modelName, "iPhone 13 Pro Max")
        XCTAssertEqual(devices[0].majorVersion, 26)
        XCTAssertFalse(devices[0].isLegacy)
        XCTAssertTrue(devices[0].isUSB)
        XCTAssertEqual(devices[1].modelName, "iPhone X")
        XCTAssertTrue(devices[1].isLegacy)
        XCTAssertFalse(devices[1].isUSB)
        XCTAssertEqual(devices[2].deviceName, "iOS device")
        XCTAssertFalse(devices[2].isLegacy)          // unknown version: assume modern
        XCTAssertEqual(DeviceModels.marketingName(for: "iPhone17,3"), "iPhone 16")
        XCTAssertNil(DeviceModels.marketingName(for: "iPhone99,9"))
        XCTAssertEqual(Device(deviceName: "x", identifier: "y", connectionType: "USB",
                              productType: "iPad16,3", productVersion: "18.0").symbolName, "ipad")
    }

    func testFormatting() {
        XCTAssertEqual(Format.distance(850), "850 m")
        XCTAssertEqual(Format.distance(1234), "1.23 km")
        XCTAssertEqual(Format.distance(25_500), "25.5 km")
        XCTAssertEqual(Format.distance(100, units: .imperial), "328 ft")
        XCTAssertEqual(Format.distance(1609.344 * 2.5, units: .imperial), "2.50 mi")
        XCTAssertEqual(Format.speed(5 / 3.6), "5.0 km/h")
        XCTAssertEqual(Format.speed(100 / 3.6), "100 km/h")
        XCTAssertEqual(Format.speed(26.8224, units: .imperial), "60 mph")
        XCTAssertEqual(Format.duration(45), "45s")
        XCTAssertEqual(Format.duration(245), "4m 05s")
        XCTAssertEqual(Format.duration(3725), "1h 02m")
        XCTAssertEqual(Format.duration(90_000), "1d 1h")
    }

    func testUnitConversionsRoundTrip() {
        for units in UnitSystem.allCases {
            let mps = 12.5
            XCTAssertEqual(units.metresPerSecond(fromDisplaySpeed: units.displaySpeed(fromMetresPerSecond: mps)),
                           mps, accuracy: 1e-9)
        }
    }

    func testLiveHelperProtocolParsing() {
        XCTAssertEqual(LiveHelper.parse(line: "@@spoof READY 48.8584 2.2945"), .ready(GeoPoint(48.8584, 2.2945)))
        XCTAssertEqual(LiveHelper.parse(line: "@@spoof OK -33.5 151.0"), .ok(GeoPoint(-33.5, 151)))
        XCTAssertEqual(LiveHelper.parse(line: "@@spoof PROBE 11.24.0 1"), .probe(version: "11.24.0", protocolVersion: 1))
        XCTAssertEqual(LiveHelper.parse(line: "@@spoof EXIT 0"), .exit(0))
        XCTAssertEqual(LiveHelper.parse(line: "@@spoof ERROR ConnectionTerminatedError: gone"),
                       .error("ConnectionTerminatedError: gone"))
        XCTAssertEqual(LiveHelper.parse(line: "@@spoof INCOMPATIBLE no service"), .incompatible("no service"))
        XCTAssertEqual(LiveHelper.parse(line: "@@spoof CLEARED"), .cleared)
        XCTAssertNil(LiveHelper.parse(line: "Press Ctrl+C to send a SIGINT"))
        XCTAssertNil(LiveHelper.parse(line: "@@spoof READY nope"))
        XCTAssertEqual(LiveHelper.setCommand(GeoPoint(1.5, -2.25)), "set 1.5 -2.25\n")
    }

    func testEmbeddedHelperScript() throws {
        XCTAssertTrue(LiveHelper.script.hasPrefix("# iosgpsspoof live-location helper"))
        XCTAssertTrue(LiveHelper.script.contains("PROTOCOL = \(LiveHelper.protocolVersion)"))
        XCTAssertTrue(LiveHelper.script.contains("def main(argv):"))
        XCTAssertEqual(LiveHelper.contentHash.count, 8)
        let url = try LiveHelper.installedScriptURL()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), LiveHelper.script)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("iosgpsspoof-live-helper-v\(LiveHelper.protocolVersion)-"))
    }

    func testLineSplitter() {
        final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var lines: [String] = []
        }
        let sink = Sink()
        let splitter = LineSplitter { line in
            sink.lock.lock(); sink.lines.append(line); sink.lock.unlock()
        }
        splitter.feed(Data("@@spoof RE".utf8))
        splitter.feed(Data("ADY 1 2\r\nsecond\nthi".utf8))
        splitter.feed(Data("rd".utf8))
        splitter.finish()
        XCTAssertTrue(splitter.waitUntilFinished(timeout: 1))
        XCTAssertEqual(sink.lines, ["@@spoof READY 1 2", "second", "third"])
    }

    func testProcessRunnerDrainsLargeOutput() throws {
        // 1 MB on stdout would deadlock a naive read-after-exit implementation.
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                           arguments: ["-c", "head -c 1048576 /dev/zero | tr '\\0' x; echo oops >&2; exit 3"],
                                           timeout: 30)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout.count, 1_048_576)
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
        XCTAssertThrowsError(try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.5))
    }
}
