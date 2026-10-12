import Foundation
import XCTest
@testable import SpooferCore

/// The pairing file is a key to the iPhone. It is made where only this user
/// can open it, and moved to its place when it's complete.
final class PairingFilePrivacyTests: XCTestCase {
    private static let udid = "00008110-000DEMO0000DEMO"
    private var directory: URL!
    private var destinationFolder: URL!
    private var changedEnvironment: [String] = []

    override func setUpWithError() throws {
        try XCTSkipIf(which("python3") == nil, "needs python3 to run the pretend pymobiledevice3")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-privacy-\(UUID().uuidString)")
        destinationFolder = directory.appendingPathComponent("shared")
        // A folder other users can read, like /Users/Shared or an external disk.
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        set("PYTHONPATH", SessionHarness.fixtures.appendingPathComponent("fake-site").path)
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
    private var file: URL { destinationFolder.appendingPathComponent("Demo iPhone.mobiledevicepairing") }
    private var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    private var pmd: Pymobiledevice3 {
        Pymobiledevice3(executableURL: SessionHarness.fixtures.appendingPathComponent("fake-pymobiledevice3"))
    }

    private func leftoverStagingFolders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("anywhere-pairing-") })
    }

    func testTheKeyIsWrittenInAPrivateFolderNotWhereItWillLive() throws {
        _ = try pmd.exportPairingFile(udid: Self.udid, to: file)
        let saveCall = try XCTUnwrap(calls.first { $0.hasPrefix("lockdown save-pair-record") }, "\(calls)")
        let written = try XCTUnwrap(saveCall.split(separator: " ").dropFirst(2).first.map(String.init))
        XCTAssertNotEqual(URL(fileURLWithPath: written).deletingLastPathComponent().standardizedFileURL.path,
                          destinationFolder.standardizedFileURL.path,
                          "the key was written straight into the shared folder")
        // Only this user can open the folder it was written in.
        XCTAssertTrue(calls.contains("save-pair-record folder-mode 700"), "\(calls)")
    }

    func testTheFinishedFileIsForThisUserOnlyAndTheDraftIsGone() throws {
        let before = leftoverStagingFolders()
        let export = try pmd.exportPairingFile(udid: Self.udid, to: file)
        XCTAssertNil(export.remotePairingProblem)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destinationFolder.path), [file.lastPathComponent])
        XCTAssertEqual(leftoverStagingFolders(), before, "a private folder was left behind")
    }

    func testAFileWithoutTheNewerIdentityIsStillPlacedAndStillPrivate() throws {
        set("FAKE_PMD_RP", "locked")
        let export = try pmd.exportPairingFile(udid: Self.udid, to: file)
        XCTAssertEqual(export.remotePairingProblem, "the iPhone is locked. Unlock it and try again.")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testNoPairingRecordIsExplainedWhateverTheToolDoesAboutIt() throws {
        // Current pymobiledevice3 exits with an error. Old ones exited with success.
        for behaviour in ["1", "legacy"] {
            set("FAKE_PMD_NO_PAIR_RECORD", behaviour)
            XCTAssertThrowsError(try pmd.exportPairingFile(udid: Self.udid, to: file), behaviour) { error in
                XCTAssertTrue("\(error)".contains("no pairing record for the iPhone"), "\(behaviour): \(error)")
                XCTAssertTrue("\(error)".contains("tap Trust"), "\(behaviour): \(error)")
                XCTAssertFalse("\(error)".contains("`pymobiledevice3"), "\(behaviour): \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), behaviour)
        }
    }

    func testAFailedExportLeavesAnEarlierFileAlone() throws {
        try Data("the earlier file".utf8).write(to: file)
        set("FAKE_PMD_NO_PAIR_RECORD", "1")
        XCTAssertThrowsError(try pmd.exportPairingFile(udid: Self.udid, to: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "the earlier file")
    }

    func testAPlaceThatCannotBeWrittenIsReportedPlainly() throws {
        let missing = destinationFolder.appendingPathComponent("no/such/folder/file.mobiledevicepairing")
        let before = leftoverStagingFolders()
        XCTAssertThrowsError(try pmd.exportPairingFile(udid: Self.udid, to: missing)) { error in
            XCTAssertTrue("\(error)".contains("couldn't save the pairing file"), "\(error)")
        }
        XCTAssertEqual(leftoverStagingFolders(), before)
    }
}
