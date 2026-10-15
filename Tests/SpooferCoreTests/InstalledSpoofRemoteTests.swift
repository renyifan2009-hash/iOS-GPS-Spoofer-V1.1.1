import Foundation
import PhoneOnlyCore
import XCTest
@testable import SpooferCore

/// Reading which SpoofRemote is on the iPhone, with the pretend pymobiledevice3
/// answering `apps list` for the current build, an old one, none, and a
/// failed read.
final class InstalledSpoofRemoteTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    private var changedEnvironment: [String] = []

    override func setUpWithError() throws {
        try XCTSkipIf(which("python3") == nil, "needs python3 to run the pretend pymobiledevice3")
    }

    override func tearDown() {
        for name in changedEnvironment { unsetenv(name) }
        changedEnvironment = []
    }

    private func set(_ name: String, _ value: String) {
        setenv(name, value, 1)
        changedEnvironment.append(name)
    }

    private var pmd: Pymobiledevice3 {
        Pymobiledevice3(executableURL: Self.fixtures.appendingPathComponent("fake-pymobiledevice3"))
    }

    private func installed() throws -> SpoofRemoteVersion? {
        try pmd.installedSpoofRemoteVersion(udid: "00008110-000DEMO0000DEMO")
    }

    func testTheCurrentBuildMatchesWhatTheCodeExpects() throws {
        set("FAKE_PMD_SPOOFREMOTE", "current")
        let version = try XCTUnwrap(try installed())
        XCTAssertEqual(version, SpoofRemote.expected)
        XCTAssertFalse(version < SpoofRemote.expected, "the current build must not read as old")
    }

    func testAnOldBuildReadsAsOlderThanExpected() throws {
        set("FAKE_PMD_SPOOFREMOTE", "old")
        let version = try XCTUnwrap(try installed())
        XCTAssertEqual(version, SpoofRemoteVersion(marketing: [1, 1], build: 4))   // what v2.4.0 shipped
        XCTAssertLessThan(version, SpoofRemote.expected)
    }

    func testNotInstalledIsNilNotAnError() throws {
        set("FAKE_PMD_SPOOFREMOTE", "none")
        XCTAssertNil(try installed())
    }

    func testAFailedCheckThrows() throws {
        set("FAKE_PMD_SPOOFREMOTE", "fail")
        XCTAssertThrowsError(try installed())
    }
}
