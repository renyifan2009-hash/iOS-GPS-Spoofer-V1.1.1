import Foundation
import XCTest
@testable import SpooferCore

/// The real location has to be back when Stop or quit says it is, however the
/// two overlap and whatever the iPhone was in the middle of.
final class SessionStopTests: XCTestCase {
    private var harness: SessionHarness!
    private let start = GeoPoint(48.8584, 2.2945)

    override func tearDown() {
        harness?.finish()
        harness = nil
    }

    /// Quitting while a Stop is still putting the real location back must wait for it.
    func testQuittingDuringAStopWaitsForTheRestore() throws {
        harness = try SessionHarness(engine: .classic, iOS: "18.0", environment: ["FAKE_PMD_CLEAR_DELAY": "1.0"])
        harness.session.start(at: start)
        XCTAssertTrue(harness.wait { harness.lines(of: harness.pmdLog).contains { $0.contains("simulate-location set") } },
                      harness.lines(of: harness.pmdLog).joined(separator: "\n"))
        XCTAssertTrue(harness.waitForState { $0 == .active })

        harness.session.stop()
        XCTAssertEqual(harness.session.state, .stopping)
        let began = Date()
        harness.session.stopBlocking()   // what Cmd-Q does
        let waited = Date().timeIntervalSince(began)

        let log = harness.lines(of: harness.pmdLog)
        XCTAssertTrue(log.contains { $0.hasPrefix("done") && $0.contains("simulate-location clear") },
                      "quit returned before the clear finished:\n" + log.joined(separator: "\n"))
        XCTAssertGreaterThan(waited, 0.5)
        XCTAssertEqual(harness.session.state, .idle)
        XCTAssertTrue(harness.session.restoredOnLastStop)
    }

    func testQuitWaitsOnlyOnceSoTheLastMomentCallIsQuick() throws {
        harness = try SessionHarness(engine: .classic, iOS: "18.0", environment: ["FAKE_PMD_CLEAR_DELAY": "0.5"])
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0 == .active })
        harness.session.stop()
        harness.session.stopBlocking()
        // `applicationWillTerminate` calls it again on the main thread.
        let began = Date()
        harness.session.stopBlocking()
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.3)
    }

    func testStopAllBlockingPutsEverySessionBack() throws {
        harness = try SessionHarness(engine: .classic, iOS: "18.0")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0 == .active })
        SpoofSession.stopAllBlocking()   // what a quit signal does
        XCTAssertEqual(harness.session.state, .idle)
        XCTAssertTrue(harness.session.restoredOnLastStop)
        XCTAssertTrue(harness.lines(of: harness.pmdLog).contains { $0.contains("simulate-location clear") })
    }

    func testAStoppedSessionIsNotStoppedAgainByAQuitSignal() throws {
        harness = try SessionHarness(engine: .classic, iOS: "18.0")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0 == .active })
        harness.session.stop()
        XCTAssertTrue(harness.waitForState { $0 == .idle })
        let clears = harness.lines(of: harness.pmdLog).filter { $0.contains("simulate-location clear") }.count
        SpoofSession.stopAllBlocking()
        XCTAssertEqual(harness.lines(of: harness.pmdLog).filter { $0.contains("simulate-location clear") }.count, clears)
    }

    /// iOS 16 and older on the classic engine: a `set` that is still running when Stop
    /// is pressed must not land after the `clear`.
    func testALateOneShotSetDoesNotLandAfterTheClear() throws {
        harness = try SessionHarness(engine: .classic, iOS: "16.7", environment: ["FAKE_PMD_SET_DELAY": "1.0"])
        harness.session.start(at: start)
        // The set is under way (its command is logged when it starts).
        XCTAssertTrue(harness.wait { harness.lines(of: harness.pmdLog).contains { $0.hasPrefix("developer simulate-location set") } },
                      harness.lines(of: harness.pmdLog).joined(separator: "\n"))
        harness.session.stop()
        XCTAssertTrue(harness.waitForState(20) { $0 == .idle })

        let log = harness.lines(of: harness.pmdLog)
        let setFinished = try XCTUnwrap(log.firstIndex { $0.hasPrefix("done developer simulate-location set") },
                                        log.joined(separator: "\n"))
        let clear = try XCTUnwrap(log.lastIndex { $0.hasPrefix("developer simulate-location clear") },
                                  log.joined(separator: "\n"))
        XCTAssertLessThan(setFinished, clear, "the clear was sent while the set was still running:\n" + log.joined(separator: "\n"))
        XCTAssertTrue(harness.session.restoredOnLastStop)
    }
}
