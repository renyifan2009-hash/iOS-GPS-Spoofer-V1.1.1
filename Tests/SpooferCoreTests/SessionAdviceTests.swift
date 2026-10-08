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

/// Which tunnel "Automatic" picks for each iOS version.
final class TransportTests: XCTestCase {
    private func device(_ version: String) -> Device {
        Device(deviceName: "Test", identifier: "00008110-TEST", connectionType: "USB",
               productType: "iPhone17,2", productVersion: version)
    }

    func testAutomaticUsesTheOwnTunnelFromIOS17Point4() {
        for version in ["17.4", "17.4.1", "17.6", "18.0", "26.6", "27.0"] {
            XCTAssertEqual(Transport.automatic.resolved(for: device(version)), .userspace, version)
            XCTAssertEqual(Transport.automatic.flags(for: device(version)), ["--userspace"], version)
        }
    }

    func testAutomaticUsesApplesTunnelOnEarlyIOS17() {
        for version in ["17.0", "17.1.2", "17.3.1"] {
            XCTAssertEqual(Transport.automatic.resolved(for: device(version)), .native, version)
        }
    }

    func testExplicitChoicesAreKept() {
        XCTAssertEqual(Transport.native.flags(for: device("26.6")), ["--native"])
        XCTAssertEqual(Transport.tunneld.flags(for: device("26.6")), ["--tunnel", "00008110-TEST"])
    }
}
