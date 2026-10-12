import Foundation
import XCTest
@testable import SpooferCore

/// After a run that was killed: what is left over, whether the real location is
/// back, and what the person is told. The sweep is given its leftovers by the
/// test, so it never looks at (or stops) a real process on this Mac.
final class StraySweepTests: XCTestCase {
    private let udid = "00008110-000DEMO0000DEMO"

    override func tearDown() {
        // A sweep that finds a hold marks the Mac as busy putting a location back.
        ChildProcessRegistry.finishRestoring()
    }

    private func hold(_ command: String) -> StrayHold? {
        StrayProcess(pid: 1, command: command).hold
    }

    // MARK: Reading a leftover's command line

    func testAnIOS17HoldCanBeCleared() throws {
        let hold = try XCTUnwrap(hold("/Users/me/Library/Application Support/AnyWhere/venv/bin/python3 -m pymobiledevice3 developer dvt simulate-location set --userspace --udid \(udid) -- 48.8584 2.2945"))
        XCTAssertEqual(hold.udid, udid)
        XCTAssertEqual(hold.clearArguments, ["developer", "dvt", "simulate-location", "clear", "--userspace", "--udid", udid])
    }

    func testAnIOS16HoldCanBeCleared() throws {
        let hold = try XCTUnwrap(hold("/opt/homebrew/bin/pymobiledevice3 developer simulate-location set --udid \(udid) -- 1 2"))
        XCTAssertEqual(hold.clearArguments, ["developer", "simulate-location", "clear", "--udid", udid])
    }

    func testARouteIsClearedThroughTheSameTunnel() throws {
        let native = try XCTUnwrap(hold("pymobiledevice3 developer dvt simulate-location play --native --udid \(udid) /tmp/route.gpx"))
        XCTAssertEqual(native.clearArguments, ["developer", "dvt", "simulate-location", "clear", "--native", "--udid", udid])
        let tunneld = try XCTUnwrap(hold("pymobiledevice3 developer dvt simulate-location set --tunnel \(udid) --udid \(udid) -- 1 2"))
        XCTAssertEqual(tunneld.clearArguments,
                       ["developer", "dvt", "simulate-location", "clear", "--tunnel", udid, "--udid", udid])
    }

    func testTheLiveHelperNeedsNothingBecauseItClearsItself() {
        let helper = StrayProcess(pid: 1, command: "/usr/bin/python3 -u /x/iosgpsspoof-live-helper-v1-ab12cd34.py -- developer dvt simulate-location set --userspace --udid \(udid) -- 1 2")
        XCTAssertTrue(helper.isLiveHelper)
        XCTAssertNil(helper.hold)
    }

    func testOtherCommandsAreNotHolds() {
        XCTAssertNil(hold("pymobiledevice3 developer dvt simulate-location clear --userspace --udid \(udid)"))
        XCTAssertNil(hold("pymobiledevice3 developer dvt simulate-location set --userspace -- 1 2"), "no iPhone named")
        XCTAssertNil(hold("pymobiledevice3 usbmux list"))
        XCTAssertNil(hold(""))
    }

    // MARK: The sweep

    private func sleeper(_ script: String = "exec sleep 60") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }

    func testAHoldThatIsStoppedIsReportedSoThePhoneCanBeCleared() throws {
        let child = try sleeper()
        defer { if child.isRunning { child.terminate() } }
        let command = "pymobiledevice3 developer dvt simulate-location set --userspace --udid \(udid) -- 1 2"

        let report = ChildProcessRegistry.sweep(find: { [StrayProcess(pid: child.processIdentifier, command: command)] },
                                                helperGrace: 0.2)
        child.waitUntilExit()

        XCTAssertEqual(report.reaped, 1)
        XCTAssertEqual(report.holds.map(\.udid), [udid])
        XCTAssertEqual(ChildProcessRegistry.lastSweep, report)
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
    }

    func testTwoHoldsOnTheSamePhoneAreOneJob() throws {
        let a = try sleeper(), b = try sleeper()
        defer { for p in [a, b] where p.isRunning { p.terminate() } }
        let command = "pymobiledevice3 developer dvt simulate-location set --userspace --udid \(udid) -- 1 2"
        let report = ChildProcessRegistry.sweep(find: {
            [StrayProcess(pid: a.processIdentifier, command: command), StrayProcess(pid: b.processIdentifier, command: command)]
        }, helperGrace: 0.2)
        a.waitUntilExit(); b.waitUntilExit()
        XCTAssertEqual(report.reaped, 2)
        XCTAssertEqual(report.holds.count, 1)
    }

    func testALiveHelperIsGivenTimeToClearBeforeItIsStopped() throws {
        // It finishes by itself after a moment, as a helper does once its input has closed.
        let helper = try sleeper("sleep 0.6")
        defer { if helper.isRunning { helper.terminate() } }
        let command = "python3 -u /x/iosgpsspoof-live-helper-v1-ab12cd34.py -- developer dvt simulate-location set --udid \(udid) -- 1 2"

        let began = Date()
        let report = ChildProcessRegistry.sweep(find: { [StrayProcess(pid: helper.processIdentifier, command: command)] },
                                                helperGrace: 5)
        helper.waitUntilExit()

        XCTAssertEqual(helper.terminationReason, .exit, "it was interrupted before it could finish")
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
        XCTAssertEqual(report.reaped, 1)
        XCTAssertTrue(report.holds.isEmpty, "a live helper puts the location back itself")
    }

    func testAHelperThatNeverFinishesIsStoppedAfterTheGrace() throws {
        let helper = try sleeper()
        defer { if helper.isRunning { helper.terminate() } }
        let command = "python3 -u /x/iosgpsspoof-live-helper-v1-ab12cd34.py -- developer dvt simulate-location set --udid \(udid) -- 1 2"
        _ = ChildProcessRegistry.sweep(find: { [StrayProcess(pid: helper.processIdentifier, command: command)] }, helperGrace: 0.3)
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationReason, .uncaughtSignal)
    }

    func testNothingLeftOverIsNothingToReport() {
        let report = ChildProcessRegistry.sweep(find: { [] }, helperGrace: 0)
        XCTAssertEqual(report, .empty)
        XCTAssertEqual(ChildProcessRegistry.lastSweep, .empty)
    }

    // MARK: Putting the location back

    func testTheLocationIsClearedOnEachPhone() throws {
        try XCTSkipIf(which("python3") == nil, "needs python3 to run the pretend pymobiledevice3")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log); unsetenv("FAKE_PMD_LOG") }
        setenv("FAKE_PMD_LOG", log.path, 1)
        let pmd = Pymobiledevice3(executableURL: SessionHarness.fixtures.appendingPathComponent("fake-pymobiledevice3"))
        let holds = [try XCTUnwrap(hold("pymobiledevice3 developer dvt simulate-location set --userspace --udid \(udid) -- 1 2"))]

        let outcome = ChildProcessRegistry.restoreLocations(of: holds, using: pmd)

        XCTAssertEqual(outcome.restored, [udid])
        XCTAssertTrue(outcome.failed.isEmpty)
        let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(calls, ["developer dvt simulate-location clear --userspace --udid \(udid)"])
    }

    func testAPhoneThatCannotBeClearedIsReportedWithTheReason() throws {
        try XCTSkipIf(which("python3") == nil, "needs python3 to run the pretend pymobiledevice3")
        setenv("FAKE_PMD_FAIL_CLEAR", "1", 1)
        defer { unsetenv("FAKE_PMD_FAIL_CLEAR") }
        let pmd = Pymobiledevice3(executableURL: SessionHarness.fixtures.appendingPathComponent("fake-pymobiledevice3"))
        let holds = [try XCTUnwrap(hold("pymobiledevice3 developer dvt simulate-location set --userspace --udid \(udid) -- 1 2"))]

        let outcome = ChildProcessRegistry.restoreLocations(of: holds, using: pmd)

        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertEqual(outcome.failed.map(\.udid), [udid])
        XCTAssertEqual(outcome.failed.first?.reason, "Device is not connected")
    }

    // MARK: Not starting over the top of it

    func testASweepThatFindsAHoldMarksTheRestoreAsUnderWay() throws {
        let child = try sleeper()
        defer { if child.isRunning { child.terminate() } }
        XCTAssertFalse(ChildProcessRegistry.isRestoringLocation)
        _ = ChildProcessRegistry.sweep(find: {
            [StrayProcess(pid: child.processIdentifier,
                          command: "pymobiledevice3 developer dvt simulate-location set --userspace --udid \(udid) -- 1 2")]
        }, helperGrace: 0.2)
        child.waitUntilExit()
        XCTAssertTrue(ChildProcessRegistry.isRestoringLocation)
        ChildProcessRegistry.finishRestoring()
        XCTAssertFalse(ChildProcessRegistry.isRestoringLocation)
    }

    func testAHelperAloneIsNothingToWaitFor() throws {
        let helper = try sleeper("exec sleep 30")
        defer { if helper.isRunning { helper.terminate() } }
        _ = ChildProcessRegistry.sweep(find: {
            [StrayProcess(pid: helper.processIdentifier,
                          command: "python3 -u /x/iosgpsspoof-live-helper-v1-ab12cd34.py -- developer dvt simulate-location set --udid \(udid) -- 1 2")]
        }, helperGrace: 0.1)
        helper.waitUntilExit()
        XCTAssertFalse(ChildProcessRegistry.isRestoringLocation)
    }

    func testRestoringEndsTheWait() throws {
        try XCTSkipIf(which("python3") == nil, "needs python3 to run the pretend pymobiledevice3")
        let child = try sleeper()
        defer { if child.isRunning { child.terminate() } }
        let report = ChildProcessRegistry.sweep(find: {
            [StrayProcess(pid: child.processIdentifier,
                          command: "pymobiledevice3 developer dvt simulate-location set --userspace --udid \(udid) -- 1 2")]
        }, helperGrace: 0.2)
        child.waitUntilExit()
        XCTAssertTrue(ChildProcessRegistry.isRestoringLocation)
        let pmd = Pymobiledevice3(executableURL: SessionHarness.fixtures.appendingPathComponent("fake-pymobiledevice3"))
        _ = ChildProcessRegistry.restoreLocations(of: report.holds, using: pmd)
        XCTAssertFalse(ChildProcessRegistry.isRestoringLocation)
    }

    func testANewSessionWaitsUntilTheLeftoverLocationIsBack() throws {
        let harness = try SessionHarness(engine: .classic, iOS: "18.0")
        defer { harness.finish() }
        let child = try sleeper()
        defer { if child.isRunning { child.terminate() } }
        _ = ChildProcessRegistry.sweep(find: {
            [StrayProcess(pid: child.processIdentifier,
                          command: "pymobiledevice3 developer dvt simulate-location set --userspace --udid \(udid) -- 1 2")]
        }, helperGrace: 0.2)
        child.waitUntilExit()

        harness.session.start(at: GeoPoint(48.8584, 2.2945))
        // While the old location is being put back, the new one is not set.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(harness.session.state, .connecting("Putting your real location back first…"))
        XCTAssertFalse(harness.lines(of: harness.pmdLog).contains { $0.contains("simulate-location set") })

        ChildProcessRegistry.finishRestoring()
        XCTAssertTrue(harness.waitForState { $0 == .active }, "\(harness.states)")
    }
}
