import Foundation
import XCTest
@testable import PhoneOnlyCore

final class OutageCounterTests: XCTestCase {
    func testOfflineAfterTwoFailuresInARow() {
        var counter = OutageCounter()
        counter.record(.failed)
        XCTAssertFalse(counter.isOffline)
        counter.record(.failed)
        XCTAssertTrue(counter.isOffline)
    }

    func testAnAnswerStartsTheCountAgain() {
        var counter = OutageCounter()
        counter.record(.failed)
        counter.record(.answered)
        counter.record(.failed)
        XCTAssertFalse(counter.isOffline)
        XCTAssertEqual(counter.failures, 1)
    }

    /// Backgrounding the app cancels the check that is running. Two of those
    /// used to make the pill say "Mac is offline".
    func testCancelledChecksAreNotOutages() {
        var counter = OutageCounter()
        XCTAssertFalse(counter.record(.cancelled))
        XCTAssertFalse(counter.record(.cancelled))
        XCTAssertFalse(counter.record(.cancelled))
        XCTAssertFalse(counter.isOffline)
        XCTAssertEqual(counter.failures, 0)
    }

    func testACancelledCheckDoesNotBreakARunOfFailures() {
        var counter = OutageCounter()
        counter.record(.failed)
        counter.record(.cancelled)
        XCTAssertEqual(counter.failures, 1)
        counter.record(.failed)
        XCTAssertTrue(counter.isOffline)
    }

    func testOutcomeOfErrors() {
        XCTAssertEqual(OutageCounter.Outcome(error: CancellationError()), .cancelled)
        XCTAssertEqual(OutageCounter.Outcome(error: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(OutageCounter.Outcome(error: URLError(.timedOut)), .failed)
        XCTAssertEqual(OutageCounter.Outcome(error: URLError(.cannotConnectToHost)), .failed)
        XCTAssertEqual(OutageCounter.Outcome(error: NSError(domain: "x", code: 1)), .failed)
    }

    func testLooksForTheMacAgainOnTheSecondFailureAndEveryFifth() {
        var counter = OutageCounter()
        var looked: [Int] = []
        for _ in 1...12 {
            counter.record(.failed)
            if counter.shouldLookAgain { looked.append(counter.failures) }
        }
        XCTAssertEqual(looked, [2, 5, 10])
    }

    func testNeverLooksAgainWithNoFailures() {
        var counter = OutageCounter()
        XCTAssertFalse(counter.shouldLookAgain)
        counter.record(.answered)
        XCTAssertFalse(counter.shouldLookAgain)
    }

    func testReset() {
        var counter = OutageCounter()
        counter.record(.failed)
        counter.record(.failed)
        counter.reset()
        XCTAssertFalse(counter.isOffline)
        XCTAssertEqual(counter.failures, 0)
    }
}
