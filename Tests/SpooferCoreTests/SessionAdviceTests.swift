import XCTest
@testable import SpooferCore

/// pymobiledevice3 errors, read in plain English: what to tell the user, and
/// whether retrying can help.
final class SessionAdviceTests: XCTestCase {
    private func advice(_ error: String) -> (message: String, permanent: Bool)? {
        SpoofSession.advice(for: error)
    }

    func testDroppedConnectionsAreRetried() {
        // From a tester's log, mid-route on iOS 26.6 over the native tunnel.
        for line in ["DTX reader exiting with error: [Errno 65] No route to host",
                     "ConnectionTerminatedError: Connection closed",
                     "Connection was terminated abruptly",
                     "ConnectionResetError: [Errno 54] Connection reset by peer",
                     "TimeoutError: timed out"] {
            let a = advice(line)
            XCTAssertNotNil(a, line)
            XCTAssertEqual(a?.permanent, false, line)
        }
    }

    func testDeveloperModeOffIsPermanent() {
        let a = advice("DeveloperModeIsNotEnabledError: developer mode is not enabled")
        XCTAssertEqual(a?.permanent, true)
        XCTAssertTrue(a?.message.contains("Settings ▸ Privacy & Security ▸ Developer Mode") ?? false)
    }

    func testThingsTheUserCanFixWhileWeRetry() {
        XCTAssertEqual(advice("PasswordRequiredError: device is password protected")?.permanent, false)
        XCTAssertEqual(advice("PairingDialogResponsePendingError")?.permanent, false)
        XCTAssertEqual(advice("UserDeniedPairingError")?.permanent, true)
    }

    func testDiskImageTroubleIsRetried() {
        let a = advice("InvalidServiceError: com.apple.instruments.dtservicehub")
        XCTAssertEqual(a?.permanent, false)
    }

    func testUnknownErrorsGetNoAdvice() {
        XCTAssertNil(advice("something nobody has seen before"))
    }
}
