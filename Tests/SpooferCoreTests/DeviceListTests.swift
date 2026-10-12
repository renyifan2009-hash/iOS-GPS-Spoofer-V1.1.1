import Foundation
import XCTest
@testable import SpooferCore

/// Reading the list of iPhones when one of them can't be reached, and telling
/// "the list can't be read" from "the iPhone isn't plugged in".
final class DeviceListTests: XCTestCase {
    private static let udid = "00008110-000DEMO0000DEMO"
    private var directory: URL!
    private var changedEnvironment: [String] = []

    override func setUpWithError() throws {
        try XCTSkipIf(which("python3") == nil, "needs python3 to run the pretend pymobiledevice3")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("device-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        set("FAKE_PMD_LOG", log.path)
        set("PYTHONDONTWRITEBYTECODE", "1")
    }

    override func tearDown() {
        for name in changedEnvironment { unsetenv(name) }
        changedEnvironment = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func set(_ name: String, _ value: String) {
        setenv(name, value, 1)
        changedEnvironment.append(name)
    }

    private var log: URL { directory.appendingPathComponent("calls.log") }
    private var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private var pmd: Pymobiledevice3 {
        Pymobiledevice3(executableURL: SessionHarness.fixtures.appendingPathComponent("fake-pymobiledevice3"))
    }

    func testAllWellIsOneCall() throws {
        let devices = try pmd.listDevices()
        XCTAssertEqual(devices.map(\.udid), [Self.udid])
        XCTAssertEqual(calls, ["usbmux list"])
        XCTAssertTrue(try pmd.presence(udid: Self.udid))
    }

    func testAnUnreachableWifiDeviceDoesNotHideTheCableOne() throws {
        set("FAKE_PMD_LIST_FAIL", "wifi")
        let devices = try pmd.listDevices()
        XCTAssertEqual(devices.map(\.udid), [Self.udid])
        XCTAssertEqual(calls, ["usbmux list", "usbmux list --usb"])
        XCTAssertTrue(pmd.isPresent(udid: Self.udid))
    }

    func testWhenOnlyTheBareListWorksThePhoneIsStillFound() throws {
        set("FAKE_PMD_LIST_FAIL", "lockdown")
        XCTAssertThrowsError(try pmd.listDevices())
        XCTAssertTrue(try pmd.presence(udid: Self.udid))
        XCTAssertTrue(pmd.isPresent(udid: Self.udid))
        let found = try XCTUnwrap(try pmd.find(udid: Self.udid))
        XCTAssertEqual(found.udid, Self.udid)
        XCTAssertEqual(found.majorVersion, 0, "a bare list says nothing about the version")
        XCTAssertFalse(try pmd.presence(udid: "SOME-OTHER-UDID"))
        XCTAssertTrue(calls.contains("usbmux list --simple"), "\(calls)")
    }

    func testAPhoneOnWifiIsNotHiddenByTheCableOnlyList() throws {
        // Another Wi-Fi device can't be reached, so the full list fails. The cable-only
        // list works but can't have this phone, which is on Wi-Fi. It is still there.
        set("FAKE_PMD_LIST_FAIL", "wifionly")
        XCTAssertEqual(try pmd.listDevices().count, 0)
        let found = try XCTUnwrap(try pmd.find(udid: Self.udid))
        XCTAssertEqual(found.udid, Self.udid)
        XCTAssertTrue(try pmd.presence(udid: Self.udid))
        // But a phone that isn't there at all is not invented, and a cable-only
        // question is answered by the cable-only list.
        XCTAssertFalse(try pmd.presence(udid: "SOME-OTHER-UDID"))
        XCTAssertNil(try pmd.find(udid: Self.udid, connection: .usb))
    }

    func testAListThatCannotBeReadIsNotAnUnpluggedPhone() throws {
        set("FAKE_PMD_LIST_FAIL", "all")
        XCTAssertThrowsError(try pmd.presence(udid: Self.udid)) { error in
            XCTAssertEqual(SpoofSession.firstLine(of: error), "Device 00008110-0000WIFI0000WIFI is not reachable")
        }
        // The old yes-or-no answer can't tell the two apart, and says no.
        XCTAssertFalse(pmd.isPresent(udid: Self.udid))
    }

    func testAnUnpluggedPhoneIsSimplyNotThere() throws {
        set("FAKE_PMD_NO_DEVICE", "1")
        XCTAssertFalse(try pmd.presence(udid: Self.udid))
        XCTAssertNil(try pmd.find(udid: Self.udid))
    }

    func testTheBareListIsReadFromStringsOrObjects() {
        XCTAssertEqual(Pymobiledevice3.simpleUDIDs(#"["A","B"]"#), ["A", "B"])
        XCTAssertEqual(Pymobiledevice3.simpleUDIDs(#"[{"Identifier":"A"},{"SerialNumber":"B"},{"x":1}]"#), ["A", "B"])
        XCTAssertEqual(Pymobiledevice3.simpleUDIDs("[]"), [])
        XCTAssertNil(Pymobiledevice3.simpleUDIDs("not json"))
    }
}

/// A session that can't read the list says so, instead of asking for a cable that is already plugged in.
final class SessionListFailureTests: XCTestCase {
    private var harness: SessionHarness!
    private let start = GeoPoint(48.8584, 2.2945)

    override func tearDown() {
        harness?.finish()
        harness = nil
    }

    func testAnUnreadableListIsReportedWithItsReasonAndNotAsAnUnpluggedPhone() throws {
        harness = try SessionHarness(engine: .classic, environment: ["FAKE_PMD_LIST_FAIL": "all"])
        harness.session.start(at: start)
        XCTAssertTrue(harness.wait { harness.logged("Couldn't read the list of iPhones", level: .warning) }, "\(harness.logs)")
        XCTAssertTrue(harness.logged("is not reachable"), "\(harness.logs)")
        XCTAssertFalse(harness.logged("plug it in"), "\(harness.logs)")
        XCTAssertFalse(harness.session.isWaitingForDevice)
        // Said once, not at every try.
        XCTAssertTrue(harness.waitForState { $0.isFailed })
        XCTAssertEqual(harness.logs.filter { $0.line.contains("Couldn't read the list of iPhones") }.count, 1)
        // And after a while it stops, with the reason.
        let message = try XCTUnwrap(harness.session.state.failureMessage)
        XCTAssertTrue(message.contains("can't read the list of iPhones"), message)
        XCTAssertTrue(message.contains("is not reachable"), message)
    }

    func testAnUnpluggedPhoneIsStillWaitedFor() throws {
        harness = try SessionHarness(engine: .classic, environment: ["FAKE_PMD_NO_DEVICE": "1"])
        harness.session.start(at: start)
        XCTAssertTrue(harness.wait { harness.logged("plug it in", level: .warning) }, "\(harness.logs)")
        XCTAssertTrue(harness.session.isWaitingForDevice)
        // No limit on waiting: someone may be fetching the cable.
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(harness.session.state.isFailed)
    }

    func testAListThatWorksAgainCarriesOn() throws {
        harness = try SessionHarness(engine: .classic, iOS: "18.0", environment: ["FAKE_PMD_LIST_FAIL": "lockdown"])
        harness.session.start(at: start)
        // The bare list finds the phone, so the session gets going.
        XCTAssertTrue(harness.waitForState { $0 == .active }, "\(harness.states)")
    }
}

/// A phone that reports no iOS version (it was locked when the list was read).
final class UnknownVersionTests: XCTestCase {
    private var harness: SessionHarness!
    private let start = GeoPoint(48.8584, 2.2945)

    override func tearDown() {
        harness?.finish()
        harness = nil
    }

    private func firstHold() -> String? {
        harness.lines(of: harness.pmdLog).first { $0.contains("simulate-location set") }
    }

    func testNoVersionGetsTheNewerTunnel() throws {
        harness = try SessionHarness(engine: .classic, iOS: "0", environment: ["FAKE_PMD_NO_VERSION": "1"])
        harness.session.start(at: start)
        XCTAssertTrue(harness.wait { firstHold() != nil }, harness.lines(of: harness.pmdLog).joined(separator: "\n"))
        let hold = try XCTUnwrap(firstHold())
        XCTAssertTrue(hold.contains("--userspace"), hold)
        XCTAssertFalse(hold.contains("--native"), hold)
    }

    func testAVersionThatTheListGivesLaterIsUsed() throws {
        // The session was made while the phone was locked (no version). By the time it
        // starts, the list says iOS 17.2: that needs Apple's tunnel.
        harness = try SessionHarness(engine: .classic, iOS: "0", environment: ["FAKE_PMD_IOS": "17.2.1"])
        harness.session.start(at: start)
        XCTAssertTrue(harness.wait { firstHold() != nil }, harness.lines(of: harness.pmdLog).joined(separator: "\n"))
        XCTAssertTrue(try XCTUnwrap(firstHold()).contains("--native"))
    }

    func testAKnownVersionIsNotSecondGuessed() throws {
        harness = try SessionHarness(engine: .classic, iOS: "18.0")
        harness.session.start(at: start)
        XCTAssertTrue(harness.wait { firstHold() != nil })
        XCTAssertTrue(try XCTUnwrap(firstHold()).contains("--userspace"))
    }

    func testAnExplicitChoiceIsKept() throws {
        // (The harness uses Automatic. A fixed choice never reaches the guess.)
        XCTAssertEqual(Transport.native.flags(for: Device(deviceName: "x", identifier: "U", connectionType: "USB",
                                                          productType: "unknown", productVersion: "0")), ["--native"])
    }
}
