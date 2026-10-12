import XCTest
@testable import SpooferCore

/// The library file is shared with the CLI and may be hand-edited, or written
/// by another build. One entry it can't read must not cost the user the rest.
final class LibraryResilienceTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("library.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-resilience-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test may leave a file unreadable on purpose.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: url)
    }

    private func files(containing word: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(word) }
    }

    // MARK: One bad entry among good ones

    func testAFavoriteWithoutADateStillLoadsAlongsideTheOthers() throws {
        // The first favorite has no "created". It used to empty the whole list.
        try write("""
        {"favorites": [
          {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Home", "latitude": 37.33, "longitude": -122.0},
          {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Work", "latitude": 37.4, "longitude": -122.1,
           "created": "2024-05-01T08:00:00Z"}
        ]}
        """)
        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library.favorites.map(\.name), ["Home", "Work"])
        XCTAssertEqual(library.favorites[0].point, GeoPoint(37.33, -122.0))
        XCTAssertEqual(report.droppedEntries, 0)
        XCTAssertNil(report.backup)
    }

    func testAPlaceNeedsOnlyWhereItIs() throws {
        try write(#"{"favorites": [{"latitude": 48.8584, "longitude": 2.2945}], "recents": [{"latitude": 1, "longitude": 2, "name": 7}]}"#)
        let library = LibraryFile.load(from: url)
        XCTAssertEqual(library.favorites.count, 1)
        XCTAssertEqual(library.favorites[0].name, "48.8584, 2.2945")
        XCTAssertEqual(library.recents.map(\.point), [GeoPoint(1, 2)])
        XCTAssertEqual(library.recents[0].name, "1.0000, 2.0000")
    }

    func testDatesWithFractionalSecondsAreKept() throws {
        try write(#"{"favorites": [{"name": "A", "latitude": 1, "longitude": 2, "created": "2024-05-01T08:00:00.250Z"}]}"#)
        let created = LibraryFile.load(from: url).favorites.first?.created
        XCTAssertEqual(created?.timeIntervalSince1970 ?? 0, 1_714_550_400.25, accuracy: 0.01)
    }

    func testOnlyTheEntryThatCannotBeReadIsLeftOut() throws {
        let original = """
        {"favorites": [
          {"name": "Home", "latitude": 37.33, "longitude": -122.0},
          {"name": "Broken", "latitude": "north", "longitude": -122.0},
          {"name": "Off the map", "latitude": 500, "longitude": 0},
          {"name": "Work", "latitude": 37.4, "longitude": -122.1}
        ], "recents": [7, {"name": "Cafe", "latitude": 3, "longitude": 4}]}
        """
        try write(original)
        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library.favorites.map(\.name), ["Home", "Work"])
        XCTAssertEqual(library.recents.map(\.name), ["Cafe"])
        XCTAssertEqual(report.droppedEntries, 3)
        // The file as it was is kept before anything can replace it.
        let backup = try XCTUnwrap(report.backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)   // loading changed nothing
        // The next save rewrites the file without the bad entries, and the copy still has them.
        try LibraryFile.save(library, to: url)
        XCTAssertEqual(LibraryFile.load(from: url).favorites.map(\.name), ["Home", "Work"])
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
    }

    func testEveryShapeOfUnreadableEntryIsSteppedPast() throws {
        // null, a string, a list, a nested object, a boolean and a number too big for a Double each sit
        // between two good entries. Loading must reach the second one (and must finish at all).
        try write("""
        {"favorites": [
          {"name": "First", "latitude": 1, "longitude": 2},
          null, "text", [1, [2, 3]], {"a": {"b": [null]}}, true, 1e999,
          {"name": "Last", "latitude": 3, "longitude": 4}
        ]}
        """)
        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library.favorites.map(\.name), ["First", "Last"])
        XCTAssertEqual(report.droppedEntries, 6)
    }

    func testTheSameFileIsOnlyCopiedOnce() throws {
        try write(#"{"favorites": [{"name": "Home", "latitude": 1, "longitude": 2}, {"nope": true}]}"#)
        _ = LibraryFile.load(from: url)
        _ = LibraryFile.load(from: url)
        _ = LibraryFile.load(from: url)
        XCTAssertEqual(files(containing: "backup").count, 1)
    }

    func testARouteWithOneBadWaypointIsLeftOutWholeNotEmptied() throws {
        try write("""
        {"routes": [
          {"name": "Good", "waypoints": [{"latitude": 1, "longitude": 2}, {"latitude": 3, "longitude": 4}]},
          {"name": "Half broken", "waypoints": [{"latitude": 1, "longitude": 2}, {"latitude": "x", "longitude": 4}]},
          {"name": "Old style"}
        ]}
        """)
        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library.routes.map(\.name), ["Good", "Old style"])
        XCTAssertEqual(library.routes[0].waypoints.count, 2)
        XCTAssertEqual(report.droppedEntries, 1)
        XCTAssertNotNil(report.backup)
    }

    func testNullAndMissingListsAreSimplyEmpty() throws {
        try write(#"{"favorites": null, "routes": []}"#)
        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library, LibraryData())
        XCTAssertEqual(report, LibraryFile.LoadReport())
    }

    func testAListThatIsNotAListCountsAsLost() throws {
        try write(#"{"favorites": {"Home": [1, 2]}, "recents": [{"name": "Cafe", "latitude": 3, "longitude": 4}]}"#)
        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library.recents.count, 1)
        XCTAssertTrue(library.favorites.isEmpty)
        XCTAssertEqual(report.droppedEntries, 1)
        XCTAssertNotNil(report.backup)
    }

    // MARK: A file that is not a library

    func testTwoBrokenFilesInOneSecondAreBothKept() throws {
        try write("{ not json")
        let first = LibraryFile.loadWithReport(from: url)
        XCTAssertNotNil(first.report.movedAside)
        try write("[ also not")
        let second = LibraryFile.loadWithReport(from: url)
        XCTAssertNotNil(second.report.movedAside)
        XCTAssertNotEqual(first.report.movedAside, second.report.movedAside)
        XCTAssertEqual(files(containing: "corrupt").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSomethingThatIsNotAnObjectIsMovedAside() throws {
        try write("[1, 2, 3]")
        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library, LibraryData())
        XCTAssertNotNil(report.movedAside)
        XCTAssertFalse(report.unreadable)
    }

    // MARK: Saving over what is there

    func testSavingKeepsACopyOfAFileItCouldNotFullyRead() throws {
        // Nothing loaded it first: the save itself must not lose the entry.
        let original = #"{"favorites": [{"name": "Home", "latitude": 1, "longitude": 2}, {"name": "Odd", "latitude": null}]}"#
        try write(original)
        try LibraryFile.save(LibraryData(favorites: [SavedPlace(name: "New", point: GeoPoint(5, 6))]), to: url)
        let backup = try XCTUnwrap(files(containing: "backup").first)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(backup), encoding: .utf8), original)
        XCTAssertEqual(LibraryFile.load(from: url).favorites.map(\.name), ["New"])
    }

    func testSavingSetsAsideAFileThatIsNotALibrary() throws {
        try write("garbage")
        try LibraryFile.save(LibraryData(favorites: [SavedPlace(name: "New", point: GeoPoint(5, 6))]), to: url)
        XCTAssertEqual(files(containing: "corrupt").count, 1)
        XCTAssertEqual(LibraryFile.load(from: url).favorites.map(\.name), ["New"])
    }

    func testAFileThatCannotBeReadIsNeverOverwritten() throws {
        try XCTSkipIf(getuid() == 0, "root can read anything")
        let original = #"{"favorites": [{"name": "Home", "latitude": 1, "longitude": 2}]}"#
        try write(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library, LibraryData())
        XCTAssertTrue(report.unreadable)
        // The app would go on with an empty list; the first change must not replace the file.
        XCTAssertThrowsError(try LibraryFile.save(LibraryData(recents: [SavedPlace(name: "x", point: GeoPoint(1, 1))]), to: url))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        XCTAssertEqual(LibraryFile.load(from: url).favorites.map(\.name), ["Home"])
    }

    func testAMissingFileIsAnEmptyLibraryAndSavesNormally() throws {
        let (library, report) = LibraryFile.loadWithReport(from: url)
        XCTAssertEqual(library, LibraryData())
        XCTAssertEqual(report, LibraryFile.LoadReport())
        try LibraryFile.save(library, to: url)
        XCTAssertTrue(files(containing: "backup").isEmpty && files(containing: "corrupt").isEmpty)
    }
}
