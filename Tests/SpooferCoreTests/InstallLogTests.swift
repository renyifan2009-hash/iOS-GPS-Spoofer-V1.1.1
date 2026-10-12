import XCTest
@testable import SpooferCore

final class InstallLogTests: XCTestCase {
    func testFindsTheFirstFailureLine() {
        let log = """
        [1/5] Checking this Mac
          ✓ macOS 27.0, Apple silicon

        ✗ The build failed.
          Sources/Foo.swift:1:1: error: nope
        ✗ a second one
        """
        XCTAssertEqual(InstallLog.failureHeadline(in: log), "The build failed.")
    }

    func testStripsColourCodes() {
        let log = "\u{1B}[31m✗ The app was built, but it crashes as soon as it starts.\u{1B}[0m\n"
        XCTAssertEqual(InstallLog.failureHeadline(in: log), "The app was built, but it crashes as soon as it starts.")
    }

    func testNoFailureLineIsNil() {
        XCTAssertNil(InstallLog.failureHeadline(in: "  ✓ fine\nnothing wrong\n"))
        XCTAssertNil(InstallLog.failureHeadline(in: ""))
        XCTAssertNil(InstallLog.failureHeadline(in: "✗   \n"), "an empty failure line says nothing")
    }

    func testReadsFromTheEndOfALargeFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anywhere-installlog-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: "building… building… building…\n", count: 20_000)
        try (filler + "✗ Couldn't copy the app into /Applications.\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(InstallLog.failureHeadline(inFileAt: url), "Couldn't copy the app into /Applications.")
    }

    func testMissingFileIsNil() {
        XCTAssertNil(InstallLog.failureHeadline(inFileAt: URL(fileURLWithPath: "/nonexistent/anywhere.log")))
    }
}
