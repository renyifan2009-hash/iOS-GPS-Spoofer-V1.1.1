import XCTest
@testable import SpooferCore

final class DiagnosticsRedactorTests: XCTestCase {
    private func redact(_ s: String) -> String { DiagnosticsRedactor.redact(s) }

    func testTheNewStyleUDIDIsHidden() {
        XCTAssertEqual(redact("pymobiledevice3 developer simulate-location set --udid 00008110-001A2B3C4D5E601E -- 1 2"),
                       "pymobiledevice3 developer simulate-location set --udid <udid> -- 1 2")
        XCTAssertEqual(redact("device 00008030-00195C100E02802E not found"), "device <udid> not found")
        XCTAssertEqual(redact("lower 00008110-001a2b3c4d5e601e case"), "lower <udid> case")
    }

    func testTheOldStyleUDIDIsHidden() {
        let udid = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
        XCTAssertEqual(redact("iPhone \(udid) connected"), "iPhone <udid> connected")
    }

    func testPrivateKeysAndCertificatesAreHiddenWhole() {
        let pem = """
        before
        -----BEGIN PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7
        abcdefghijklmnopqrstuvwxyz0123456789
        -----END PRIVATE KEY-----
        after
        """
        let out = redact(pem)
        XCTAssertEqual(out, "before\n<redacted key>\nafter")
        XCTAssertFalse(out.contains("MIIEvQ"))
    }

    func testAKeyBlockThatWasCutOffIsStillHidden() {
        let out = redact("log\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0gun")
        XCTAssertEqual(out, "log\n<redacted key>")
    }

    func testLongEncodedBlobsAreHidden() {
        let blob = Data((0..<120).map { UInt8(($0 * 37 + 11) % 256) }).base64EncodedString()   // 160 characters, padded
        XCTAssertEqual(redact("record: \(blob) end"), "record: <redacted data> end")
        // A line of a wrapped plist <data> block is caught on its own.
        XCTAssertEqual(redact("  \(String(blob.prefix(76)))"), "  <redacted data>")
    }

    func testSecretsAfterTheirNameAreHidden() {
        XCTAssertEqual(redact("token=abc123XYZ"), "token=<redacted>")
        XCTAssertEqual(redact("Authorization: Bearer abc.def.ghi"), "Authorization: <redacted>")
        XCTAssertEqual(redact("sent header bearer abc.def.ghi to the Mac"), "sent header Bearer <redacted> to the Mac")
        XCTAssertEqual(redact("password: hunter2"), "password: <redacted>")
        XCTAssertEqual(redact("api_key = sk-123"), "api_key = <redacted>")
    }

    func testAnAppleIDIsHidden() {
        XCTAssertEqual(redact("signed in as someone.name+dev@icloud.com today"), "signed in as <email> today")
    }

    func testTheMacUsersNameIsHiddenInPaths() {
        XCTAssertEqual(redact("/Users/samarthvaka/Library/Logs/AnyWhere/install.log"), "/Users/<user>/Library/Logs/AnyWhere/install.log")
        XCTAssertEqual(redact("at /Users/jo smith/x"), "at /Users/<user> smith/x")   // a space ends the name: no way to tell, errs on hiding the first word
    }

    func testLongPathsAreNotMistakenForEncodedData() {
        let path = "/Users/<user>/Library/Application Support/AnyWhere/venv/lib/python3.12/site-packages/pymobiledevice3/services/dvt/instruments/location_simulation.py"
        XCTAssertEqual(redact(path), path)
        let long = "/private/var/folders/zz/0123456789abcdefghijklmnopqrstuvwxyz0123456789/T/AnyWhere-selftest-ABCDEF/AnyWhere.app/Contents/MacOS/AnyWhere"
        XCTAssertEqual(redact(long), long)
    }

    func testOrdinaryReportTextIsUntouched() {
        let lines = [
            "AnyWhere 2.4.0 (commit 9d41662, built 2026-10-12)",
            "macOS Version 15.7 (Build 24G222), Apple silicon",
            "pymobiledevice3: 11.0.0 at ~/Library/Application Support/AnyWhere/venv/bin/pymobiledevice3",
            "iPhone: iPhone 16 Pro Max (iPhone17,2), iOS 26.6, USB, Developer Mode on, tunnel lockdown",
            "[05:14:51] Teleported to Eiffel Tower, Paris (48.85840, 2.29450).",
            "Session: Live (live engine)",
            "https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3/releases/latest",
        ]
        for line in lines { XCTAssertEqual(redact(line), line) }
    }

    func testRedactingTwiceChangesNothingMore() {
        let text = "udid 00008110-001A2B3C4D5E601E token=abc /Users/me/x me@example.com"
        let once = redact(text)
        XCTAssertEqual(redact(once), once)
    }

    func testEmptyAndHugeInputsAreFine() {
        XCTAssertEqual(redact(""), "")
        let big = String(repeating: "line of ordinary text 12345\n", count: 20_000)
        XCTAssertEqual(redact(big), big)
    }
}
