import Foundation
import XCTest
@testable import SpooferCore

/// What pymobiledevice3 really prints, read the way a person needs it. Its
/// command line turns each error into a plain sentence and never prints the
/// name of the exception, so the names in the old tests were never seen.
final class RealSentenceAdviceTests: XCTestCase {
    /// A full line as `coloredlogs` writes it, cleaned the way the session cleans it.
    private func advice(_ sentence: String) -> (message: String, permanent: Bool)? {
        let line = "2026-10-12 01:02:03 laptop pymobiledevice3[4242] ERROR \(sentence)"
        return SpoofSession.advice(for: SpoofSession.cleanLogLine(line))
    }

    func testTappingDontTrustStopsAtOnce() {
        let a = advice("User refused to trust this computer")
        XCTAssertEqual(a?.permanent, true)
        XCTAssertTrue(a?.message.contains("Don't Trust") ?? false)
    }

    func testTrustPromptsTheUserCanStillAnswerAreRetried() {
        for sentence in ["Device is not paired", "Waiting for user dialog approval"] {
            let a = advice(sentence)
            XCTAssertEqual(a?.permanent, false, sentence)
            XCTAssertTrue(a?.message.contains("Tap Trust") ?? false, sentence)
        }
    }

    func testFailedToStartServiceIsRetriedAsDiskImageTrouble() {
        let a = advice("Failed to start service. Possible reasons are:")
        XCTAssertEqual(a?.permanent, false)
        XCTAssertTrue(a?.message.contains("developer support") ?? false)
    }

    func testTheOtherRealSentencesStillWork() {
        XCTAssertEqual(advice("Developer Mode is disabled. You can try to enable it using: python3 -m pymobiledevice3 amfi enable-developer-mode")?.permanent, true)
        XCTAssertEqual(advice("Device is password protected. Please unlock and retry")?.permanent, false)
        XCTAssertEqual(advice("Connection was terminated abruptly")?.permanent, false)
    }

    func testNotConnectedIsLeftToTheReconnectLoop() {
        XCTAssertNil(advice("Device is not connected"))
    }

    func testACommandLineTheToolRefusesIsPermanentAndSaysWhatToDo() {
        let line = SpoofSession.commandRejection(in: "│ No such option: --userspace                          │")
        let a = SpoofSession.advice(for: line ?? "")
        XCTAssertEqual(a?.permanent, true)
        XCTAssertTrue(a?.message.contains("too old") ?? false)
        XCTAssertTrue(a?.message.contains("Update") ?? false)
    }
}

final class ToolOutputReadingTests: XCTestCase {
    private let box = """
        Usage: pymobiledevice3 developer dvt simulate-location set [OPTIONS] LATITUDE LONGITUDE
        Try 'pymobiledevice3 developer dvt simulate-location set -h' for help.
        ╭─ Error ──────────────────────────────────────────────╮
        │ No such option: --userspace                          │
        │ Did you mean --native?                               │
        ╰──────────────────────────────────────────────────────╯

        """

    func testTheRowsOfAnErrorBoxAreTheReason() {
        let result = ProcessResult(status: 2, stdout: "", stderr: box)
        XCTAssertEqual(result.errorReason, "No such option: --userspace Did you mean --native?")
        XCTAssertEqual(result.errorSummary, "No such option: --userspace\nDid you mean --native?")
    }

    func testAnAsciiBoxIsReadTheSameWay() {
        let ascii = """
            Usage: x set [OPTIONS]
            +- Error ------------------------------+
            | No such option: --bogus              |
            +--------------------------------------+
            """
        let result = ProcessResult(status: 2, stdout: "", stderr: ascii)
        XCTAssertEqual(result.errorReason, "No such option: --bogus")
    }

    func testOtherBoxesAreNotTheReason() {
        let help = """
            ╭─ Options ────────────────────╮
            │ --udid  TEXT  the device     │
            ╰──────────────────────────────╯
            2026-10-12 01:02:03 laptop pymobiledevice3[1] ERROR Device is not connected
            """
        let result = ProcessResult(status: 1, stdout: "", stderr: help)
        XCTAssertEqual(result.errorReason, "Device is not connected")
        XCTAssertFalse(result.errorSummary.contains("--udid"))
    }

    func testALogLineLosesItsPrefix() {
        let log = "2026-10-12 01:02:03 laptop pymobiledevice3[1] ERROR Device not found: usbmux has no device matching udid X\n"
        XCTAssertEqual(ProcessResult(status: 1, stdout: "", stderr: log).errorReason,
                       "Device not found: usbmux has no device matching udid X")
    }

    func testSilenceHasNoReason() {
        XCTAssertNil(ProcessResult(status: 1, stdout: "", stderr: "").errorReason)
    }

    func testTheRefusalIsFoundInABoxRow() {
        XCTAssertNotNil(SpoofSession.commandRejection(in: "│ No such option: --native │"))
        XCTAssertNotNil(SpoofSession.commandRejection(in: "Error: No such option: --native"))
        XCTAssertNotNil(SpoofSession.commandRejection(in: "No such command 'dvt'."))
        // A value we got wrong is our own bug, not an old tool.
        XCTAssertNil(SpoofSession.commandRejection(in: "│ Invalid value for 'LATITUDE': abc │"))
        XCTAssertNil(SpoofSession.commandRejection(in: "╭─ Error ─────────────╮"))
    }
}

final class ToolVersionTests: XCTestCase {
    func testReadingAVersion() {
        XCTAssertEqual(ToolVersion("11.25.0")?.parts, [11, 25, 0])
        XCTAssertEqual(ToolVersion("pymobiledevice3 9.30.1\n")?.parts, [9, 30, 1])
        XCTAssertNil(ToolVersion("unknown"))
        XCTAssertNil(ToolVersion(""))
    }

    func testOrder() throws {
        XCTAssertLessThan(try XCTUnwrap(ToolVersion("9.2.0")), ToolVersion.userspaceFloor)
        XCTAssertLessThan(try XCTUnwrap(ToolVersion("9.29.9")), ToolVersion.userspaceFloor)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ToolVersion("9.30.0")), ToolVersion.userspaceFloor)
        XCTAssertGreaterThan(try XCTUnwrap(ToolVersion("10.0.0")), ToolVersion.userspaceFloor)
        XCTAssertLessThan(try XCTUnwrap(ToolVersion("10.9.9")), ToolVersion.nativeFloor)
        XCTAssertEqual(try XCTUnwrap(ToolVersion("11.0")), ToolVersion.nativeFloor)
        // 11.9 is older than 11.25: compared as numbers, not as text.
        XCTAssertLessThan(try XCTUnwrap(ToolVersion("11.9.0")), try XCTUnwrap(ToolVersion("11.25.0")))
    }
}

/// A run that fails shows its reason, not its command line, wherever the app prints it.
final class FailureReasonTests: XCTestCase {
    private var harness: SessionHarness!

    override func tearDown() {
        harness?.finish()
        harness = nil
    }

    func testAFailedRunShowsWhyAndKeepsTheCommandForBugReports() throws {
        harness = try SessionHarness(engine: .classic, environment: ["FAKE_PMD_FAIL_CLEAR": "1"])
        let error = try XCTUnwrap(failure { _ = try harness.pmd.run(["developer", "dvt", "simulate-location", "clear", "--udid", "X"]) })
        XCTAssertEqual(SpoofSession.firstLine(of: error), "Device is not connected")
        XCTAssertEqual(SpoofSession.toolErrorDetail(error), "Device is not connected")
        XCTAssertEqual(error.localizedDescription, "Device is not connected")
        XCTAssertTrue("\(error)".hasPrefix("`pymobiledevice3 developer dvt simulate-location clear"), "\(error)")
    }

    func testARunThatSaysNothingStillExplainsItself() throws {
        // `usbmux list` for a device that isn't there prints no error at all when it fails like this.
        let result = ProcessResult(status: 3, stdout: "", stderr: "")
        let error = SpoofError("`pymobiledevice3 x` failed (3)\n", reason: result.errorReason ?? "pymobiledevice3 stopped with status 3")
        XCTAssertEqual(SpoofSession.firstLine(of: error), "pymobiledevice3 stopped with status 3")
    }

    func testAnOrdinaryErrorKeepsItsFirstLine() {
        XCTAssertEqual(SpoofSession.firstLine(of: SpoofError("first\nsecond")), "first")
    }

    func testATimeoutSaysSo() throws {
        let error = try XCTUnwrap(failure {
            _ = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 1)
        })
        XCTAssertEqual(SpoofSession.firstLine(of: error), "sleep didn't answer within 1 second")
    }

    func testStoppingFailsWithItsReason() throws {
        harness = try SessionHarness(engine: .classic, environment: ["FAKE_PMD_FAIL_CLEAR": "1"])
        harness.session.start(at: GeoPoint(48.8584, 2.2945))
        XCTAssertTrue(harness.waitForState { $0 == .active }, "\(harness.states)")
        harness.session.stop()
        XCTAssertTrue(harness.waitForState { $0 == .idle })
        XCTAssertFalse(harness.session.restoredOnLastStop)
        let message = try XCTUnwrap(harness.logs.first { $0.level == .error && $0.line.contains("put the real location back") }?.line,
                                    "\(harness.logs)")
        XCTAssertTrue(message.contains("Device is not connected"), message)
        XCTAssertFalse(message.contains("`pymobiledevice3"), message)
        XCTAssertTrue(message.contains("Restarting the iPhone always clears it"), message)
    }

    private func failure(_ body: () throws -> Void) -> Error? {
        do { try body() } catch { return error }
        return nil
    }
}

/// The two ways a session learns why pymobiledevice3 stopped: the live helper
/// (its output and the tool's own), and a classic hold.
final class SessionStopReasonTests: XCTestCase {
    private var harness: SessionHarness!
    private let start = GeoPoint(48.8584, 2.2945)

    override func tearDown() {
        harness?.finish()
        harness = nil
    }

    func testDontTrustIsNotRetried() throws {
        harness = try SessionHarness(engine: .live, helperModes: "trust")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0.isFailed }, "\(harness.states)")
        XCTAssertTrue(harness.session.state.failureMessage?.contains("Don't Trust") ?? false,
                      "\(String(describing: harness.session.state.failureMessage))")
        // One try. Not the nine that would have popped the Trust question nine times.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(harness.helperLaunches, 1)
        XCTAssertFalse(harness.logged("retrying"), "\(harness.logs)")
    }

    func testAToolThatIsTooOldIsNotRetriedAndSaysSo() throws {
        harness = try SessionHarness(engine: .live, helperModes: "usage")
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0.isFailed }, "\(harness.states)")
        XCTAssertTrue(harness.session.state.failureMessage?.contains("too old") ?? false,
                      "\(String(describing: harness.session.state.failureMessage))")
        XCTAssertEqual(harness.helperLaunches, 1)
        XCTAssertTrue(harness.logged("No such option: --userspace", level: .error), "\(harness.logs)")
        // And it says which version is installed (the pretend one reports 11.25.0).
        XCTAssertTrue(harness.wait { harness.logged("pymobiledevice3 11.25.0 is installed") }, "\(harness.logs)")
    }

    func testAClassicHoldThatTheToolRefusesIsNotRetriedEither() throws {
        harness = try SessionHarness(engine: .classic, environment: ["FAKE_PMD_USAGE_ERROR": "1"])
        harness.session.start(at: start)
        XCTAssertTrue(harness.waitForState { $0.isFailed }, "\(harness.states)")
        XCTAssertTrue(harness.session.state.failureMessage?.contains("too old") ?? false,
                      "\(String(describing: harness.session.state.failureMessage))")
        let holds = harness.lines(of: harness.pmdLog).filter { $0.contains("simulate-location set") }
        XCTAssertEqual(holds.count, 1, "\(holds)")
    }
}
