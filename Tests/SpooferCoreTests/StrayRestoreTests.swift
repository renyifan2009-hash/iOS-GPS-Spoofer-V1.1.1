import XCTest
@testable import SpooferCore

final class StrayRestoreTests: XCTestCase {
    func testAClearInProgressIsNotAStray() {
        XCTAssertTrue(ChildProcessRegistry.isRestoringTheRealLocation(
            "/Users/x/venv/bin/pymobiledevice3 developer simulate-location clear --udid 00008110-001A2B3C4D5E601E"))
        XCTAssertTrue(ChildProcessRegistry.isRestoringTheRealLocation(
            "python3 -m pymobiledevice3 developer dvt simulate-location clear --rsd 127.0.0.1 49152"))
    }

    func testHoldingAndMovingProcessesStillAre() {
        XCTAssertFalse(ChildProcessRegistry.isRestoringTheRealLocation(
            "pymobiledevice3 developer simulate-location set --udid ABC -- 37.33 -122.0"))
        XCTAssertFalse(ChildProcessRegistry.isRestoringTheRealLocation(
            "pymobiledevice3 developer dvt simulate-location play route.gpx --udid ABC"))
        XCTAssertFalse(ChildProcessRegistry.isRestoringTheRealLocation("iosgpsspoof-live-helper"))
        XCTAssertFalse(ChildProcessRegistry.isRestoringTheRealLocation(""))
    }
}
