import XCTest

/// What the sidebar says when there is no iPhone, and when to blame the helper instead of the
/// cable (Logic/DeviceListHealth.swift, linked into this test target as GUILogic).
final class DeviceListHealthTests: XCTestCase {
    func testOneFailedScanIsAHiccup() {
        var health = DeviceListHealth()
        XCTAssertFalse(health.failed("timed out"))
        XCTAssertFalse(health.isFailing)
        XCTAssertNil(health.error)
    }

    func testTwoInARowBlameTheHelperAndAreReportedOnce() {
        var health = DeviceListHealth()
        XCTAssertFalse(health.failed("usbmux list failed"))
        XCTAssertTrue(health.failed("usbmux list failed"), "the second failure is the one to log")
        XCTAssertTrue(health.isFailing)
        XCTAssertEqual(health.error, "usbmux list failed")
        // Every later scan fails too: no more warnings, so the log isn't flooded every 3 seconds.
        XCTAssertFalse(health.failed("usbmux list failed"))
        XCTAssertFalse(health.failed("usbmux list failed"))
        XCTAssertTrue(health.isFailing)
    }

    func testASuccessfulScanClearsIt() {
        var health = DeviceListHealth()
        health.failed("one")
        health.failed("two")
        health.succeeded()
        XCTAssertFalse(health.isFailing)
        XCTAssertNil(health.error)
        // And it takes two new failures to blame the helper again.
        XCTAssertFalse(health.failed("three"))
        XCTAssertNil(health.error)
    }

    func testTheLatestErrorIsTheOneShown() {
        var health = DeviceListHealth()
        health.failed("first problem")
        health.failed("second problem")
        health.failed("third problem")
        XCTAssertEqual(health.error, "third problem")
    }

    // MARK: Sidebar

    func testWithoutTheHelperTheSidebarNeverSpinsOrSaysPlugItIn() {
        // The bug: pmd == nil returned before "has refreshed" was set, so this spun forever.
        XCTAssertEqual(SidebarEmptyState.resolve(helperInstalled: false, hasLookedOnce: false, listError: nil), .helperMissing)
        XCTAssertEqual(SidebarEmptyState.resolve(helperInstalled: false, hasLookedOnce: true, listError: "x"), .helperMissing)
    }

    func testAFailingHelperIsNotReportedAsNoIPhone() {
        XCTAssertEqual(SidebarEmptyState.resolve(helperInstalled: true, hasLookedOnce: true, listError: "usbmux list failed"),
                       .listFailed("usbmux list failed"))
    }

    func testTheOrdinaryStates() {
        XCTAssertEqual(SidebarEmptyState.resolve(helperInstalled: true, hasLookedOnce: false, listError: nil), .searching)
        XCTAssertEqual(SidebarEmptyState.resolve(helperInstalled: true, hasLookedOnce: true, listError: nil), .noIPhone)
    }
}
