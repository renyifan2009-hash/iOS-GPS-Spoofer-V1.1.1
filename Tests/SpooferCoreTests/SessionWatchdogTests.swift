import Foundation
import XCTest
@testable import SpooferCore

/// The decisions the watchdog makes, with no phone and no clock.
final class WatchdogDecisionTests: XCTestCase {
    private let timing = SpoofSession.Timing()   // 15 s quiet, 15 s to answer
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func live(unackedFor: TimeInterval? = nil, quietFor: TimeInterval = 0, slept: Bool = false)
        -> SpoofSession.WatchdogAction {
        SpoofSession.watchdogAction(
            engine: .live, now: now,
            unackedSince: unackedFor.map { now.addingTimeInterval(-$0) },
            lastOKAt: now.addingTimeInterval(-quietFor), sleptSinceLastLook: slept, timing: timing)
    }

    func testAHealthyChannelIsLeftAlone() {
        XCTAssertEqual(live(quietFor: 3), .none)
        XCTAssertEqual(live(unackedFor: 2, quietFor: 2), .none)
    }

    func testAQuietChannelIsAskedForAnAnswer() {
        XCTAssertEqual(live(quietFor: 16), .heartbeat)
    }

    func testNoAnswerForTooLongMeansDead() {
        guard case .dead = live(unackedFor: 16, quietFor: 20) else { return XCTFail("expected dead") }
        // Moving all the time doesn't hide it: the oldest unanswered message counts.
        guard case .dead = live(unackedFor: 40, quietFor: 40) else { return XCTFail("expected dead") }
    }

    func testWhileWaitingForAnAnswerNothingElseIsSent() {
        XCTAssertEqual(live(unackedFor: 5, quietFor: 30), .none)
    }

    func testAfterSleepTheChannelIsCheckedAtOnce() {
        XCTAssertEqual(live(quietFor: 1, slept: true), .heartbeat)
    }

    func testAClassicHoldCanOnlyBeToldTheMacSlept() {
        for slept in [false, true] {
            let action = SpoofSession.watchdogAction(engine: .classic, now: now, unackedSince: nil,
                                                     lastOKAt: .distantPast, sleptSinceLastLook: slept, timing: timing)
            XCTAssertEqual(action, slept ? .restartAfterSleep : .none)
        }
    }

    func testTheDeadMessageSaysItTimedOut() {
        // The words that `advice(for:)` reads as a dropped connection, not as something to fix.
        guard case let .dead(message) = live(unackedFor: 99) else { return XCTFail("expected dead") }
        XCTAssertNotNil(SpoofSession.advice(for: message))
        XCTAssertEqual(SpoofSession.advice(for: message)?.permanent, false)
    }
}

final class SleepProbeTests: XCTestCase {
    func testNormalTimePassingIsNotSleep() {
        var probe = SleepProbe(now: Date(timeIntervalSince1970: 100), awake: 50)
        XCTAssertFalse(probe.sleptSinceLastLook(now: Date(timeIntervalSince1970: 105), awake: 55, gap: 10))
    }

    func testTheWallClockRunningAheadIsSleep() {
        var probe = SleepProbe(now: Date(timeIntervalSince1970: 100), awake: 50)
        // 90 seconds went by on the wall clock, 5 on the awake clock.
        XCTAssertTrue(probe.sleptSinceLastLook(now: Date(timeIntervalSince1970: 190), awake: 55, gap: 10))
        // And it is only reported once.
        XCTAssertFalse(probe.sleptSinceLastLook(now: Date(timeIntervalSince1970: 195), awake: 60, gap: 10))
    }

    func testASmallClockAdjustmentIsNotSleep() {
        var probe = SleepProbe(now: Date(timeIntervalSince1970: 100), awake: 50)
        XCTAssertFalse(probe.sleptSinceLastLook(now: Date(timeIntervalSince1970: 108), awake: 55, gap: 10))
    }
}

/// A session running the pretend live helper.
final class SessionWatchdogTests: XCTestCase {
    private var harness: SessionHarness!

    override func tearDown() {
        harness?.finish()
        harness = nil
    }

    private let start = GeoPoint(48.8584, 2.2945)

    func testAHealthyChannelIsKeptAliveAndNotReplaced() throws {
        harness = try SessionHarness(engine: .live, helperModes: "ok")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0 == .active }, "\(harness.states)")
        // Nothing moves, yet the channel keeps being asked for an answer.
        XCTAssertTrue(harness.wait { harness.helperSets >= 3 }, harness.lines(of: harness.helperLog).joined(separator: "\n"))
        XCTAssertEqual(harness.helperLaunches, 1)
        XCTAssertEqual(harness.session.state, .active)
        // The spot sent again is the one the phone is at.
        XCTAssertTrue(harness.lines(of: harness.helperLog).contains { $0.hasPrefix("set 48.8584 2.2945") })
    }

    func testAChannelThatStopsAnsweringIsReplacedAtTheLatestSpot() throws {
        harness = try SessionHarness(engine: .live, helperModes: "silent,ok")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0 == .active })
        // The person moves while the channel is dead. The move is not lost.
        harness.session.move(to: GeoPoint(40.6892, -74.0445))

        XCTAssertTrue(harness.wait { harness.helperLaunches == 2 }, "no second helper: \(harness.states)")
        XCTAssertTrue(harness.logged("stopped answering", level: .warning), "\(harness.logs)")
        XCTAssertTrue(harness.lines(of: harness.helperLog).contains("start 40.6892 -74.0445"),
                      harness.lines(of: harness.helperLog).joined(separator: "\n"))
        XCTAssertTrue(harness.waitForState { $0 == .active })
        XCTAssertTrue(harness.states.contains { if case .reconnecting = $0 { return true } else { return false } })
    }

    func testAChannelThatKeepsGoingSilentEndsInAnError() throws {
        harness = try SessionHarness(engine: .live, helperModes: "silent")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState(15) { $0.isFailed }, "\(harness.states)")
        XCTAssertTrue(harness.session.state.failureMessage?.contains("Lost the connection") ?? false)
        // The reason kept is the one that ended it, not whatever the helper printed dying.
        XCTAssertTrue(harness.logged("last error: Timed out"), "\(harness.logs)")
        // The first try plus one per retry delay.
        XCTAssertEqual(harness.helperLaunches, SessionHarness.fastTiming.retryDelays.count + 1)
    }

    func testAChannelThatOpensAndDropsAgainEventuallyGivesUp() throws {
        // Before, each READY cleared the failure count, so this retried for ever.
        harness = try SessionHarness(engine: .live, helperModes: "die")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState(15) { $0.isFailed }, "\(harness.states)")
        XCTAssertEqual(harness.helperLaunches, SessionHarness.fastTiming.retryDelays.count + 1)
    }

    func testAChannelThatRecoversStartsCountingAgain() throws {
        var timing = SessionHarness.fastTiming
        timing.healthyRun = 0.2
        // Two drops, a channel that works for half a second (longer than healthyRun)
        // and then drops, two more drops, and finally a good one. With only three
        // retries allowed, the fifth failure in a row would end the session. The
        // half second of good health in the middle starts the count again.
        harness = try SessionHarness(engine: .live, helperModes: "die,die,okdie,die,die,ok", timing: timing)
        harness.session.start(at: start)
        XCTAssertTrue(harness.wait(15) { harness.helperLaunches == 6 }, "\(harness.states)")
        XCTAssertTrue(harness.waitForState { $0 == .active }, "\(harness.states)")
        XCTAssertFalse(harness.states.contains { $0.isFailed }, "\(harness.states)")
    }

    func testChannelMayBeStaleAsksALiveChannelAtOnce() throws {
        harness = try SessionHarness(engine: .live, helperModes: "ok")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0 == .active })
        // Quiet for less than the heartbeat interval: only this call can cause a set.
        let before = harness.helperSets
        harness.session.channelMayBeStale()
        XCTAssertTrue(harness.wait { harness.helperSets > before })
        XCTAssertEqual(harness.helperLaunches, 1)
    }

    func testChannelMayBeStaleDoesNothingWithoutAChannel() throws {
        harness = try SessionHarness(engine: .live, helperModes: "ok")
        harness.session.channelMayBeStale()
        XCTAssertEqual(harness.session.state, .idle)
        XCTAssertEqual(harness.helperLaunches, 0)
    }

    func testAClassicHoldIsRestartedWhenItMayBeStale() throws {
        harness = try SessionHarness(engine: .classic, iOS: "18.0")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0 == .active }, "\(harness.states)")
        func holds() -> Int { harness.lines(of: harness.pmdLog).filter { $0.contains("simulate-location set") }.count }
        XCTAssertTrue(harness.wait { holds() == 1 }, harness.lines(of: harness.pmdLog).joined(separator: "\n"))

        harness.session.channelMayBeStale()
        XCTAssertTrue(harness.wait { holds() == 2 }, harness.lines(of: harness.pmdLog).joined(separator: "\n"))
        XCTAssertTrue(harness.waitForState { $0 == .active })
        // Ending it on purpose is not a failure: nothing is said about retrying.
        XCTAssertFalse(harness.logged("retrying"), "\(harness.logs)")
    }
}
