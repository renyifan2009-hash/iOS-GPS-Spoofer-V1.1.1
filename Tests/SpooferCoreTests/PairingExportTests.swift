import Foundation
import PhoneOnlyCore
import XCTest
@testable import SpooferCore

/// What the export's Python prints, and what the Mac makes of it.
final class RemotePairingScriptOutputTests: XCTestCase {
    private func identityLine(_ keys: [String: Any]) throws -> String {
        let plist = try PropertyListSerialization.data(fromPropertyList: keys, format: .xml, options: 0)
        return RemotePairingScript.prefix + "IDENTITY " + plist.base64EncodedString()
    }

    private var keys: [String: Any] {
        ["public_key": Data(repeating: 1, count: 32), "private_key": Data(repeating: 2, count: 32),
         "identifier": "MAC-ID", "alt_irk": Data(repeating: 3, count: 16)]
    }

    func testAnIdentity() throws {
        let identity = try RemotePairingScript.parse(try identityLine(keys) + "\n").get()
        XCTAssertEqual(identity.identifier, "MAC-ID")
        XCTAssertEqual(identity.publicKey, Data(repeating: 1, count: 32))
        XCTAssertEqual(identity.privateKey, Data(repeating: 2, count: 32))
        XCTAssertEqual(identity.altIRK, Data(repeating: 3, count: 16))
    }

    func testOtherOutputAroundItIsIgnored() throws {
        let stdout = "a warning some library printed\n" + (try identityLine(keys)) + "\r\nbye\n"
        XCTAssertEqual(try RemotePairingScript.parse(stdout).get().identifier, "MAC-ID")
    }

    func testAReason() {
        let result = RemotePairingScript.parse("@@pairing ERROR the iPhone is locked. Unlock it and try again.\n")
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual("\(error)", "the iPhone is locked. Unlock it and try again.")
        }
    }

    func testNoAnswerAtAll() {
        XCTAssertThrowsError(try RemotePairingScript.parse("").get())
        XCTAssertThrowsError(try RemotePairingScript.parse("Traceback (most recent call last):\n").get())
    }

    func testAnIdentityOfTheWrongShapeIsRefused() throws {
        var short = keys
        short["private_key"] = Data(repeating: 2, count: 16)
        XCTAssertThrowsError(try RemotePairingScript.parse(try identityLine(short)).get())
        XCTAssertThrowsError(try RemotePairingScript.parse("@@pairing IDENTITY not-base64!").get())
    }
}

/// `exportPairingFile` from end to end, with the pretend iPhone: the fake
/// `pymobiledevice3` command for the lockdown record, and the fake library on
/// PYTHONPATH for the Remote Pairing identity.
final class PairingExportTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    private var directory: URL!
    private var changedEnvironment: [String] = []

    override func setUpWithError() throws {
        try XCTSkipIf(which("python3") == nil, "needs python3 to run the pretend pymobiledevice3")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        set("PYTHONPATH", Self.fixtures.appendingPathComponent("fake-site").path)
        set("PYTHONDONTWRITEBYTECODE", "1")
        set("FAKE_PMD_LOG", log.path)
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
    private var file: URL { directory.appendingPathComponent("Demo iPhone.mobiledevicepairing") }
    private var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func export() throws -> Pymobiledevice3.PairingExport {
        let pmd = Pymobiledevice3(executableURL: Self.fixtures.appendingPathComponent("fake-pymobiledevice3"))
        return try pmd.exportPairingFile(udid: "00008110-000DEMO0000DEMO", to: file)
    }

    private func savedRecord() throws -> PairingRecord {
        try PairingRecord(data: Data(contentsOf: file))
    }

    func testTheFileHasBothIdentities() throws {
        let export = try export()
        XCTAssertNil(export.remotePairingProblem)
        XCTAssertTrue(export.worksOnEveryIOSVersion)

        // What SpoofRemote will make of it.
        let record = try savedRecord()
        XCTAssertTrue(record.hasLockdownRecord)
        XCTAssertEqual(record.remotePairing?.identifier, "F3B1A0C2-FA4E-3000-8000-00000000FA4E")
        XCTAssertEqual(record.remotePairing?.publicKey, Data(0..<32))
        XCTAssertEqual(record.remotePairing?.privateKey, Data(100..<132))
        XCTAssertEqual(record.remotePairing?.altIRK, Data(200..<216))

        XCTAssertTrue(calls.contains("lockdown wifi-connections on --udid 00008110-000DEMO0000DEMO"))
        // Over the cable, and without starting a lockdown pairing of its own.
        XCTAssertTrue(calls.contains("lib create_using_usbmux serial=00008110-000DEMO0000DEMO connection_type=USB autopair=False"),
                      "\(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("lib connect") }.count, 1)
    }

    func testTheFileIsForThisUserOnly() throws {
        _ = try export()
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testANewPairingIsCheckedWithASecondConnect() throws {
        set("FAKE_PMD_RP", "fresh")
        XCTAssertNil(try export().remotePairingProblem)
        XCTAssertTrue(try savedRecord().hasRemotePairingIdentity)
        XCTAssertEqual(calls.filter { $0.hasPrefix("lib connect") }.count, 2)
    }

    func testAPairingTheIPhoneNeverAcceptsIsReported() throws {
        set("FAKE_PMD_RP", "never")
        let export = try export()
        XCTAssertEqual(export.remotePairingProblem, "the iPhone paired but then didn't accept the pairing. Try again.")
        XCTAssertFalse(export.worksOnEveryIOSVersion)
        // The file is still there, for iOS versions that answer lockdown.
        let record = try savedRecord()
        XCTAssertTrue(record.hasLockdownRecord)
        XCTAssertFalse(record.hasRemotePairingIdentity)
    }

    func testAnOldPymobiledevice3IsReported() throws {
        set("FAKE_PMD_RP", "missing")
        let problem = try XCTUnwrap(try export().remotePairingProblem)
        XCTAssertTrue(problem.contains("Update pymobiledevice3"), problem)
        XCTAssertFalse(try savedRecord().hasRemotePairingIdentity)
    }

    func testALockedIPhoneIsReported() throws {
        set("FAKE_PMD_RP", "locked")
        XCTAssertEqual(try export().remotePairingProblem, "the iPhone is locked. Unlock it and try again.")
    }

    func testAnIPhoneNotOnACableIsReported() throws {
        set("FAKE_PMD_NO_DEVICE", "1")
        XCTAssertEqual(try export().remotePairingProblem,
                       "the iPhone isn't connected with a cable. Plug it in and try again.")
    }

    func testNoLockdownRecordIsAnError() {
        set("FAKE_PMD_NO_PAIR_RECORD", "1")
        XCTAssertThrowsError(try export()) { error in
            XCTAssertTrue("\(error)".contains("no pairing record"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnOldFileAtTheSamePlaceIsReplaced() throws {
        try Data("left over".utf8).write(to: file)
        XCTAssertNil(try export().remotePairingProblem)
        XCTAssertTrue(try savedRecord().hasRemotePairingIdentity)
    }
}
