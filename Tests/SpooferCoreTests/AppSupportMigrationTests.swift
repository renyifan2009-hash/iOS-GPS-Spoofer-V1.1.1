import XCTest
@testable import SpooferCore

/// The product was renamed from "iOS GPS Spoofer" to "AnyWhere": saved places, routes and the
/// remote's pairing must follow the user to the new folder, and nothing may be lost.
final class AppSupportMigrationTests: XCTestCase {
    private var root: URL!
    private var legacy: URL!
    private var new: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("anywhere-migration-\(UUID().uuidString)")
        legacy = root.appendingPathComponent("iOS GPS Spoofer")
        new = root.appendingPathComponent("AnyWhere")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func testCopiesSavedPlacesAndPairingIntoTheNewFolder() throws {
        try write("{\"favorites\":[]}", to: "library.json", in: legacy)
        try write("{\"serverID\":\"abc\"}", to: "remote-pairing.json", in: legacy)

        let copied = AppSupport.migrateLegacyData(from: legacy, to: new)

        XCTAssertEqual(copied, ["library.json", "remote-pairing.json"])
        XCTAssertEqual(read("library.json", in: new), "{\"favorites\":[]}")
        XCTAssertEqual(read("remote-pairing.json", in: new), "{\"serverID\":\"abc\"}")
    }

    func testNeverDeletesFromTheOldFolder() throws {
        try write("keep me", to: "library.json", in: legacy)
        AppSupport.migrateLegacyData(from: legacy, to: new)
        XCTAssertEqual(read("library.json", in: legacy), "keep me")
    }

    func testNeverOverwritesWhatTheNewFolderAlreadyHas() throws {
        try write("old", to: "library.json", in: legacy)
        try write("newer", to: "library.json", in: new)

        let copied = AppSupport.migrateLegacyData(from: legacy, to: new)

        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(read("library.json", in: new), "newer")
    }

    func testDoesNotCopyThePythonEnvironmentOrHelpers() throws {
        let venv = legacy.appendingPathComponent("venv/bin")
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        try "#!/stale/absolute/path".write(to: venv.appendingPathComponent("pymobiledevice3"), atomically: true, encoding: .utf8)
        try write("print('hi')", to: "live_helper.py", in: legacy.appendingPathComponent("helpers"))
        try write("{}", to: "library.json", in: legacy)

        let copied = AppSupport.migrateLegacyData(from: legacy, to: new)

        XCTAssertEqual(copied, ["library.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent("venv").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent("helpers").path))
    }

    func testCopiesFoldersWholeAndIsSafeToRunTwice() throws {
        try write("a", to: "route.gpx", in: legacy.appendingPathComponent("routes"))

        XCTAssertEqual(AppSupport.migrateLegacyData(from: legacy, to: new), ["routes"])
        XCTAssertEqual(read("route.gpx", in: new.appendingPathComponent("routes")), "a")
        XCTAssertEqual(AppSupport.migrateLegacyData(from: legacy, to: new), [], "second run changes nothing")
    }

    func testNoOldFolderIsNotAnError() {
        let missing = root.appendingPathComponent("never-existed")
        XCTAssertEqual(AppSupport.migrateLegacyData(from: missing, to: new), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "nothing to copy, so no empty folder is made")
    }

    func testFolderNamesAreWhatTheInstallerUses() {
        // setup.sh uses the same two names; if one side changes, saved places would be lost.
        XCTAssertEqual(AppSupport.folderName, "AnyWhere")
        XCTAssertEqual(AppSupport.legacyFolderName, "iOS GPS Spoofer")
        XCTAssertEqual(AppSupport.helperEnvironment.lastPathComponent, "venv")
        XCTAssertEqual(AppSupport.legacyHelperEnvironment.deletingLastPathComponent().lastPathComponent, "iOS GPS Spoofer")
    }
}
