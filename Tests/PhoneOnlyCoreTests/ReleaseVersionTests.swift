import Foundation
import XCTest
@testable import PhoneOnlyCore

final class ReleaseVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(ReleaseVersion("2.3.0")?.components, [2, 3, 0])
        XCTAssertEqual(ReleaseVersion("v2.3.0")?.components, [2, 3, 0])
        // A CI build suffix isn't part of the version.
        XCTAssertEqual(ReleaseVersion("2.3.0-ci.45")?.components, [2, 3, 0])
        XCTAssertEqual(ReleaseVersion("v2.3.0+build.7")?.components, [2, 3, 0])
        XCTAssertNil(ReleaseVersion(""))
        XCTAssertNil(ReleaseVersion("nightly"))
    }

    func testOrdering() {
        XCTAssertLessThan(ReleaseVersion("2.3.0")!, ReleaseVersion("2.3.1")!)
        XCTAssertLessThan(ReleaseVersion("2.3.0")!, ReleaseVersion("2.4.0")!)
        XCTAssertLessThan(ReleaseVersion("2.9.0")!, ReleaseVersion("2.10.0")!)
        // A missing part counts as zero.
        XCTAssertEqual(ReleaseVersion("2.3")!, ReleaseVersion("2.3.0")!)
        XCTAssertFalse(ReleaseVersion("2.3.0")! < ReleaseVersion("2.3.0")!)
    }

    func testIsNewer() {
        XCTAssertTrue(ReleaseUpdate.isNewer(latest: "v2.4.0", than: "2.3.0"))
        XCTAssertFalse(ReleaseUpdate.isNewer(latest: "v2.3.0", than: "2.3.0"))
        XCTAssertFalse(ReleaseUpdate.isNewer(latest: "v2.2.0", than: "2.3.0"))
        // Anything unreadable: say nothing.
        XCTAssertFalse(ReleaseUpdate.isNewer(latest: nil, than: "2.3.0"))
        XCTAssertFalse(ReleaseUpdate.isNewer(latest: "garbage", than: "2.3.0"))
        XCTAssertFalse(ReleaseUpdate.isNewer(latest: "v2.4.0", than: nil))
    }

    func testShouldShowRespectsDismissal() {
        // Newer release, nothing dismissed: show it.
        XCTAssertTrue(ReleaseUpdate.shouldShow(latest: "v2.4.0", current: "2.3.0", dismissed: nil))
        // Dismissed exactly this release: don't show it again.
        XCTAssertFalse(ReleaseUpdate.shouldShow(latest: "v2.4.0", current: "2.3.0", dismissed: "2.4.0"))
        // A release newer than the dismissed one: show it again.
        XCTAssertTrue(ReleaseUpdate.shouldShow(latest: "v2.5.0", current: "2.3.0", dismissed: "2.4.0"))
        // Not newer than this build: never show it.
        XCTAssertFalse(ReleaseUpdate.shouldShow(latest: "v2.3.0", current: "2.3.0", dismissed: nil))
        // Unreadable latest: say nothing.
        XCTAssertFalse(ReleaseUpdate.shouldShow(latest: nil, current: "2.3.0", dismissed: nil))
    }
}
