import XCTest
@testable import SpooferCore

final class PhoneAppTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("anywhere-phoneapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A real zip with `Payload/<app>/Info.plist` (a BINARY plist, like a built app has).
    private func makeIPA(named name: String = "test.ipa", app: String = "AnyWhere.app", plist: [String: Any],
                         extraFiles: [String: Data] = [:]) throws -> URL {
        let staging = root.appendingPathComponent("stage-\(UUID().uuidString)")
        let appDir = staging.appendingPathComponent("Payload/\(app)")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertEqual(data.prefix(6), Data("bplist".utf8), "the test must use a binary plist")
        try data.write(to: appDir.appendingPathComponent("Info.plist"))
        for (path, contents) in extraFiles {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url)
        }
        let ipa = root.appendingPathComponent(name)
        // zip must run inside the staging folder so the archive's paths start with "Payload/".
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-qr", ipa.path, "Payload"]
        try? FileManager.default.removeItem(at: ipa)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return ipa
    }

    private let anywhereInfo: [String: Any] = [
        "CFBundleIdentifier": "com.iosgpsspoof.remote", "CFBundleShortVersionString": "1.1",
        "CFBundleVersion": "3", "CFBundleDisplayName": "AnyWhere",
    ]

    // MARK: Inside an .ipa

    func testReadsABinaryPlistFromAnIPA() throws {
        let info = try PhoneApp.inspect(ipa: try makeIPA(plist: anywhereInfo))
        XCTAssertEqual(info, PhoneApp.Info(bundleID: "com.iosgpsspoof.remote", version: "1.1", build: "3", displayName: "AnyWhere"))
    }

    func testVerifyAcceptsAnyWhereAndRejectsOtherApps() throws {
        XCTAssertNoThrow(try PhoneApp.verify(ipa: try makeIPA(plist: anywhereInfo)))
        var other = anywhereInfo
        other["CFBundleIdentifier"] = "com.example.other"
        XCTAssertThrowsError(try PhoneApp.verify(ipa: try makeIPA(named: "other.ipa", plist: other))) { error in
            XCTAssertEqual(error as? PhoneApp.Problem, .wrongApp(bundleID: "com.example.other"))
        }
    }

    func testANumericBuildIsReadToo() throws {
        var numeric = anywhereInfo
        numeric["CFBundleVersion"] = 7
        XCTAssertEqual(try PhoneApp.inspect(ipa: try makeIPA(plist: numeric)).build, "7")
    }

    func testAFrameworksPlistIsNotTheApp() throws {
        // Only a nested Info.plist exists: Payload/AnyWhere.app/Frameworks/F.framework/Info.plist.
        let staging = root.appendingPathComponent("nested")
        let nested = staging.appendingPathComponent("Payload/AnyWhere.app/Frameworks/F.framework")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: anywhereInfo, format: .binary, options: 0)
            .write(to: nested.appendingPathComponent("Info.plist"))
        let ipa = root.appendingPathComponent("nested.ipa")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-qr", ipa.path, "Payload"]
        try process.run(); process.waitUntilExit()
        XCTAssertThrowsError(try PhoneApp.inspect(ipa: ipa)) { XCTAssertEqual($0 as? PhoneApp.Problem, .noApp) }
    }

    func testNotAZipIsSaidPlainly() throws {
        let file = root.appendingPathComponent("photo.ipa")
        try Data("not a zip at all".utf8).write(to: file)
        XCTAssertThrowsError(try PhoneApp.inspect(ipa: file)) { XCTAssertEqual($0 as? PhoneApp.Problem, .notAZip) }
        XCTAssertFalse(PhoneApp.Problem.notAZip.description.isEmpty)
    }

    func testAZipWithoutAnAppHasNoApp() throws {
        let staging = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: staging.appendingPathComponent("docs/readme.txt"))
        let zipURL = root.appendingPathComponent("empty.ipa")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-qr", zipURL.path, "docs"]
        try process.run(); process.waitUntilExit()
        XCTAssertThrowsError(try PhoneApp.inspect(ipa: zipURL)) { XCTAssertEqual($0 as? PhoneApp.Problem, .noApp) }
    }

    // MARK: Checksums

    func testSHA256OfAFile() throws {
        let file = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try PhoneApp.sha256(ofFileAt: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testReadsTheExpectedChecksumForAName() {
        let hashA = String(repeating: "a", count: 64)
        let hashB = String(repeating: "b", count: 64)
        let text = """
        \(hashA)  AnyWhere-2.4.0.dmg
        \(hashB)  AnyWhere.ipa
        not a checksum line
        """
        XCTAssertEqual(PhoneApp.expectedChecksum(for: "AnyWhere.ipa", inChecksumFile: text), hashB)
        XCTAssertEqual(PhoneApp.expectedChecksum(for: "AnyWhere-2.4.0.dmg", inChecksumFile: text), hashA)
        XCTAssertNil(PhoneApp.expectedChecksum(for: "missing.ipa", inChecksumFile: text))
    }

    func testChecksumLinesMayHaveDirectoriesStarsAndCapitals() {
        let hash = String(repeating: "C", count: 64)
        XCTAssertEqual(PhoneApp.expectedChecksum(for: "AnyWhere.ipa", inChecksumFile: "\(hash) *./AnyWhere-ipa/AnyWhere.ipa"),
                       hash.lowercased())
        // A short or non-hex hash is not a checksum.
        XCTAssertNil(PhoneApp.expectedChecksum(for: "AnyWhere.ipa", inChecksumFile: "abc123  AnyWhere.ipa"))
        XCTAssertNil(PhoneApp.expectedChecksum(for: "AnyWhere.ipa", inChecksumFile: String(repeating: "z", count: 64) + "  AnyWhere.ipa"))
    }

    // MARK: Downloads and signing tools

    func testDownloadURL() {
        XCTAssertEqual(PhoneApp.downloadURL(asset: "AnyWhere.ipa", repository: "o/r")?.absoluteString,
                       "https://github.com/o/r/releases/latest/download/AnyWhere.ipa")
        XCTAssertNil(PhoneApp.downloadURL(asset: "../evil", repository: "o/r"))
        XCTAssertNil(PhoneApp.downloadURL(asset: "", repository: "o/r"))
    }

    func testFindsInstalledSideloaders() throws {
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Sideloadly.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("AltServer.app"), withIntermediateDirectories: true)
        let found = PhoneApp.installedSideloaders(in: [apps])
        XCTAssertEqual(found.map(\.name), ["Sideloadly", "AltStore"])
        XCTAssertEqual(found.first?.appURL.lastPathComponent, "Sideloadly.app")
        XCTAssertTrue(PhoneApp.installedSideloaders(in: [root.appendingPathComponent("none")]).isEmpty)
    }
}
