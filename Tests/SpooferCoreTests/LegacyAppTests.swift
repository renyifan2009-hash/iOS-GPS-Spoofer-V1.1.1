import XCTest
@testable import SpooferCore

final class LegacyAppTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("anywhere-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(named name: String, in directory: String) throws -> URL {
        let url = root.appendingPathComponent(directory).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        return url
    }

    func testFindsTheOldNamedCopyInEachFolder() throws {
        let a = try makeApp(named: LegacyApp.bundleName, in: "Applications")
        let b = try makeApp(named: LegacyApp.bundleName, in: "home/Applications")
        let found = LegacyApp.leftovers(in: [root.appendingPathComponent("Applications"), root.appendingPathComponent("home/Applications")])
        XCTAssertEqual(found.map(\.path), [a.path, b.path])
    }

    func testIgnoresTheNewApp() throws {
        _ = try makeApp(named: "AnyWhere.app", in: "Applications")
        XCTAssertTrue(LegacyApp.leftovers(in: [root.appendingPathComponent("Applications")]).isEmpty)
    }

    func testNeverReportsTheCopyThatIsRunning() throws {
        let old = try makeApp(named: LegacyApp.bundleName, in: "Applications")
        XCTAssertTrue(LegacyApp.leftovers(in: [root.appendingPathComponent("Applications")], excluding: old).isEmpty)
    }

    func testMissingFoldersAreFine() {
        XCTAssertTrue(LegacyApp.leftovers(in: [root.appendingPathComponent("nope")]).isEmpty)
    }

    func testAFileWithThatNameIsNotAnApp() throws {
        let dir = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent(LegacyApp.bundleName), atomically: true, encoding: .utf8)
        XCTAssertTrue(LegacyApp.leftovers(in: [dir]).isEmpty)
    }
}
