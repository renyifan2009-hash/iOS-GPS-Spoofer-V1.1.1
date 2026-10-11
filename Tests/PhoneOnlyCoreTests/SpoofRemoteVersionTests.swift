import Foundation
import XCTest
@testable import PhoneOnlyCore

final class SpoofRemoteVersionTests: XCTestCase {
    func testReadsNumbersFromTheStringsAnAppReports() {
        let version = SpoofRemoteVersion(marketing: "1.1", build: "3")
        XCTAssertEqual(version.marketing, [1, 1])
        XCTAssertEqual(version.build, 3)
        XCTAssertEqual(version.displayString, "1.1 (3)")
    }

    func testToleratesOddVersionStrings() {
        XCTAssertEqual(SpoofRemoteVersion(marketing: "v1.2.0", build: "4 (beta)").marketing, [1, 2, 0])
        XCTAssertEqual(SpoofRemoteVersion(marketing: "v1.2.0", build: "4 (beta)").build, 4)
        // Nothing to read: an empty version and build 0.
        let empty = SpoofRemoteVersion(marketing: "", build: "")
        XCTAssertEqual(empty.marketing, [])
        XCTAssertEqual(empty.build, 0)
        XCTAssertEqual(empty.displayString, "? (0)")
    }

    func testOrdersByUserVersionThenBuild() {
        XCTAssertLessThan(SpoofRemoteVersion(marketing: [1, 1], build: 2),
                          SpoofRemoteVersion(marketing: [1, 1], build: 3))
        XCTAssertLessThan(SpoofRemoteVersion(marketing: [1, 1], build: 9),
                          SpoofRemoteVersion(marketing: [1, 2], build: 1))
        // A missing part counts as zero: 1.1 == 1.1.0.
        XCTAssertEqual(SpoofRemoteVersion(marketing: [1, 1], build: 3),
                       SpoofRemoteVersion(marketing: [1, 1, 0], build: 3))
        XCTAssertFalse(SpoofRemoteVersion(marketing: [1, 1], build: 3)
                       < SpoofRemoteVersion(marketing: [1, 1], build: 3))
    }

    /// The version in the code and the one in project.yml must match, or the
    /// Mac would warn about the wrong version. This fails if someone bumps one
    /// and forgets the other.
    func testExpectedVersionMatchesProjectYml() throws {
        let projectYml = Self.repoRoot
            .appendingPathComponent("iPhoneRemote/project.yml")
        let text = try String(contentsOf: projectYml, encoding: .utf8)
        let marketing = try XCTUnwrap(Self.quotedValue(of: "MARKETING_VERSION", in: text),
                                      "MARKETING_VERSION not found in project.yml")
        let build = try XCTUnwrap(Self.quotedValue(of: "CURRENT_PROJECT_VERSION", in: text),
                                  "CURRENT_PROJECT_VERSION not found in project.yml")
        XCTAssertEqual(SpoofRemote.expected, SpoofRemoteVersion(marketing: marketing, build: build),
                       "SpoofRemote.expected (\(SpoofRemote.expected.displayString)) and project.yml "
                       + "(\(marketing) (\(build))) disagree. Bump both together.")
    }

    func testBundleIdentifierMatchesProjectYml() throws {
        let text = try String(contentsOf: Self.repoRoot.appendingPathComponent("iPhoneRemote/project.yml"),
                              encoding: .utf8)
        XCTAssertEqual(SpoofRemote.bundleID, Self.quotedValue(of: "PRODUCT_BUNDLE_IDENTIFIER", in: text))
    }

    // MARK: - Helpers

    /// The repository root, from this test file's path.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The value after `key:` on its line, with surrounding quotes removed.
    private static func quotedValue(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\(key):") {
            guard let colon = line.range(of: "\(key):") else { continue }
            let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
