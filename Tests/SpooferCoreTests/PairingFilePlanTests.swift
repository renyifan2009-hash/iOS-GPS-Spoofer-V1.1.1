import XCTest
@testable import SpooferCore

final class PairingFilePlanTests: XCTestCase {
    private func device(name: String = "Sam's iPhone", version: String = "26.6") -> Device {
        Device(deviceName: name, identifier: "00008140-001", connectionType: "USB", productType: "iPhone17,2", productVersion: version)
    }

    // MARK: Readiness

    func testReadyWhenHelperAndNewEnoughDeviceArePresent() {
        let state = PairingFileReadiness.evaluate(helperAvailable: true, device: device())
        XCTAssertEqual(state, .ready(deviceName: "Sam's iPhone"))
        XCTAssertTrue(state.isReady)
        XCTAssertEqual(state.title, "Sam's iPhone is ready")
    }

    func testMissingHelperIsReportedBeforeAnythingElse() {
        // Even with no device: the helper is what the person can fix first.
        XCTAssertEqual(PairingFileReadiness.evaluate(helperAvailable: false, device: nil), .helperMissing)
        XCTAssertEqual(PairingFileReadiness.evaluate(helperAvailable: false, device: device()), .helperMissing)
        XCTAssertTrue(PairingFileReadiness.helperMissing.instruction.contains("Install"))
    }

    func testNoDevice() {
        let state = PairingFileReadiness.evaluate(helperAvailable: true, device: nil)
        XCTAssertEqual(state, .noDevice)
        XCTAssertFalse(state.isReady)
        XCTAssertTrue(state.instruction.contains("USB cable"))
        XCTAssertTrue(state.instruction.contains("Trust"))
    }

    func testTooOldIOSNamesTheVersionAndTheFix() {
        for version in ["16.7.2", "17.3", "15.0"] {
            let state = PairingFileReadiness.evaluate(helperAvailable: true, device: device(version: version))
            XCTAssertEqual(state, .iosTooOld(deviceName: "Sam's iPhone", version: version), version)
            XCTAssertTrue(state.title.contains(version))
            XCTAssertTrue(state.instruction.contains("17.4"))
        }
    }

    func testIOS174AndNewerAreReady() {
        for version in ["17.4", "17.7.1", "18.0", "26.6"] {
            XCTAssertTrue(PairingFileReadiness.evaluate(helperAvailable: true, device: device(version: version)).isReady, version)
        }
    }

    // MARK: File name and place

    func testFileNameUsesTheDeviceName() {
        XCTAssertEqual(PairingFileLocation.fileName(forDevice: "Sam's iPhone"),
                       "AnyWhere Pairing File – Sam's iPhone.mobiledevicepairing")
    }

    func testFileNameNeverHasPathCharacters() {
        let name = PairingFileLocation.fileName(forDevice: "a/b:c\\d\ne")
        XCTAssertFalse(name.dropLast(".mobiledevicepairing".count).contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("\\"))
        XCTAssertFalse(name.contains("\n"))
        XCTAssertTrue(name.hasSuffix(".mobiledevicepairing"))
    }

    func testEmptyOrDotNamesFallBack() {
        XCTAssertEqual(PairingFileLocation.fileName(forDevice: ""), "AnyWhere Pairing File – iPhone.mobiledevicepairing")
        XCTAssertEqual(PairingFileLocation.fileName(forDevice: "   "), "AnyWhere Pairing File – iPhone.mobiledevicepairing")
        XCTAssertEqual(PairingFileLocation.fileName(forDevice: "..."), "AnyWhere Pairing File – iPhone.mobiledevicepairing")
    }

    func testLongNamesAreCut() {
        let name = PairingFileLocation.fileName(forDevice: String(repeating: "x", count: 500))
        XCTAssertLessThan(name.count, 120)
        XCTAssertTrue(name.hasSuffix(".mobiledevicepairing"))
    }

    func testDefaultDirectoryIsADirectoryThatExists() {
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: PairingFileLocation.defaultDirectory().path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testTheDirectoryCanBeOverriddenForTestsAndDemos() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anywhere-pairing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let chosen = PairingFileLocation.defaultDirectory(environment: ["ANYWHERE_PAIRING_DIR": dir.path])
        XCTAssertEqual(chosen.standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "it is created when missing")
        // An empty value means "not set".
        XCTAssertNotEqual(PairingFileLocation.defaultDirectory(environment: ["ANYWHERE_PAIRING_DIR": ""]).path, "")
    }

    func testDefaultURLIsInsideTheDefaultDirectory() {
        let url = PairingFileLocation.defaultURL(forDevice: "Sam's iPhone")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                       PairingFileLocation.defaultDirectory().standardizedFileURL.path)
        XCTAssertEqual(url.pathExtension, PairingFileLocation.fileExtension)
    }
}
