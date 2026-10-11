import Foundation
import XCTest
@testable import PhoneOnlyCore

/// Pairing files in the shapes the Mac app writes (the values aren't real).
enum Sample {
    static var lockdown: [String: Any] {
        [
            "DeviceCertificate": Data("device".utf8), "HostCertificate": Data("host".utf8),
            "HostPrivateKey": Data("host-key".utf8), "RootCertificate": Data("root".utf8),
            "RootPrivateKey": Data("root-key".utf8), "EscrowBag": Data("escrow".utf8),
            "HostID": "HOST-ID", "SystemBUID": "SYSTEM-BUID", "WiFiMACAddress": "00:11:22:33:44:55",
        ]
    }

    static func remotePairing(key: UInt8 = 7, identifier: String = "F3B1A0C2-0000-3000-8000-000000000001",
                              altIRK: Data? = Data(repeating: 9, count: 16)) -> [String: Any] {
        var keys: [String: Any] = [
            "public_key": Data(repeating: key, count: 32),
            "private_key": Data(repeating: key &+ 1, count: 32),
            "identifier": identifier,
        ]
        if let altIRK { keys["alt_irk"] = altIRK }
        return keys
    }

    static var both: [String: Any] { lockdown.merging(remotePairing()) { _, new in new } }

    static func plist(_ dictionary: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
    }

    static func record(_ dictionary: [String: Any]) throws -> PairingRecord {
        try PairingRecord(data: plist(dictionary))
    }
}

final class PairingRecordTests: XCTestCase {
    func testLockdownRecordAlone() throws {
        let record = try Sample.record(Sample.lockdown)
        XCTAssertTrue(record.hasLockdownRecord)
        XCTAssertNil(record.remotePairing)
        XCTAssertFalse(record.hasRemotePairingIdentity)
    }

    func testRemotePairingIdentityAlone() throws {
        let record = try Sample.record(Sample.remotePairing())
        XCTAssertFalse(record.hasLockdownRecord)
        XCTAssertEqual(record.remotePairing?.identifier, "F3B1A0C2-0000-3000-8000-000000000001")
        XCTAssertEqual(record.remotePairing?.publicKey, Data(repeating: 7, count: 32))
        XCTAssertEqual(record.remotePairing?.privateKey, Data(repeating: 8, count: 32))
        XCTAssertEqual(record.remotePairing?.altIRK, Data(repeating: 9, count: 16))
    }

    func testBothIdentitiesInOneFile() throws {
        let record = try Sample.record(Sample.both)
        XCTAssertTrue(record.hasLockdownRecord)
        XCTAssertTrue(record.hasRemotePairingIdentity)
    }

    func testBinaryPropertyListsWork() throws {
        let record = try PairingRecord(data: Sample.plist(Sample.both, format: .binary))
        XCTAssertTrue(record.hasLockdownRecord)
        XCTAssertTrue(record.hasRemotePairingIdentity)
    }

    func testTheIdentityNeedsNoAltIRK() throws {
        // pymobiledevice3 11.0.0 saves none.
        let record = try Sample.record(Sample.remotePairing(altIRK: nil))
        XCTAssertNotNil(record.remotePairing)
        XCTAssertNil(record.remotePairing?.altIRK)
    }

    func testRejectsWhatIsNotAPairingFile() {
        XCTAssertThrowsError(try PairingRecord(data: Data("hello".utf8))) { error in
            XCTAssertEqual(error as? PairingRecord.Problem, .notAPropertyList)
        }
        XCTAssertThrowsError(try PairingRecord(data: Sample.plist(["Name": "not a pairing file"]))) { error in
            XCTAssertEqual(error as? PairingRecord.Problem, .noIdentity)
        }
        // A property list whose top level is an array.
        let array = try? PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
        XCTAssertThrowsError(try PairingRecord(data: XCTUnwrap(array))) { error in
            XCTAssertEqual(error as? PairingRecord.Problem, .notAPropertyList)
        }
    }

    func testALockdownRecordMissingAKeyIdeviceNeedsIsNotOne() {
        for key in ["DeviceCertificate", "HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey",
                    "HostID", "SystemBUID", "WiFiMACAddress"] {
            var partial = Sample.lockdown
            partial[key] = nil
            XCTAssertThrowsError(try Sample.record(partial), "without \(key)")
        }
        // The escrow bag is optional (an Apple Watch has none).
        var noEscrow = Sample.lockdown
        noEscrow["EscrowBag"] = nil
        XCTAssertNoThrow(try Sample.record(noEscrow))
    }

    func testAnIdentityOfTheWrongShapeIsNotOne() throws {
        var shortKey = Sample.remotePairing()
        shortKey["private_key"] = Data(repeating: 1, count: 31)
        XCTAssertThrowsError(try Sample.record(shortKey))

        var textKey = Sample.remotePairing()
        textKey["public_key"] = String(repeating: "a", count: 32)
        XCTAssertThrowsError(try Sample.record(textKey))

        var noName = Sample.remotePairing()
        noName["identifier"] = ""
        XCTAssertThrowsError(try Sample.record(noName))

        // With a good lockdown record beside it, the file still opens: as a lockdown file.
        let record = try Sample.record(Sample.lockdown.merging(shortKey) { _, new in new })
        XCTAssertTrue(record.hasLockdownRecord)
        XCTAssertFalse(record.hasRemotePairingIdentity)
    }

    func testSettingTheIdentityKeepsTheLockdownRecord() throws {
        let lockdownOnly = try Sample.record(Sample.lockdown)
        let identity = PairingRecord.RemotePairingIdentity(publicKey: Data(repeating: 1, count: 32),
                                                           privateKey: Data(repeating: 2, count: 32),
                                                           identifier: "MAC")
        let merged = try lockdownOnly.settingRemotePairing(identity)
        XCTAssertTrue(merged.hasLockdownRecord)
        XCTAssertEqual(merged.remotePairing, identity)

        // The rest of the file is untouched.
        let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: merged.data, format: nil)
            as? [String: Any])
        XCTAssertEqual(dictionary["HostID"] as? String, "HOST-ID")
        XCTAssertEqual(dictionary["EscrowBag"] as? Data, Data("escrow".utf8))
        XCTAssertEqual(dictionary.count, Sample.lockdown.count + 3)
    }

    func testSettingAnIdentityWithoutAnAltIRKDropsTheOldOne() throws {
        // The old one belongs to the old key.
        let record = try Sample.record(Sample.both)
        let identity = PairingRecord.RemotePairingIdentity(publicKey: Data(repeating: 1, count: 32),
                                                           privateKey: Data(repeating: 2, count: 32),
                                                           identifier: "MAC")
        XCTAssertNil(try record.settingRemotePairing(identity).remotePairing?.altIRK)
    }

    func testAdoptingTheSameIdentityChangesNothing() throws {
        let record = try Sample.record(Sample.both)
        // What idevice writes back after a plain pair-verify: the identity alone.
        XCTAssertNil(record.adoptingRemotePairing(from: Sample.plist(Sample.remotePairing()), tunnelOpened: true))
        // The Mac's file had no alt_irk and idevice's copy does: still the same keys.
        let bare = try Sample.record(Sample.remotePairing(altIRK: nil))
        XCTAssertNil(bare.adoptingRemotePairing(from: Sample.plist(Sample.remotePairing()), tunnelOpened: true))
    }

    func testAdoptingANewIdentityAfterPairingAgain() throws {
        let record = try Sample.record(Sample.both)
        let renewed = try XCTUnwrap(record.adoptingRemotePairing(from: Sample.plist(Sample.remotePairing(key: 40)),
                                                                 tunnelOpened: true))
        XCTAssertEqual(renewed.remotePairing?.publicKey, Data(repeating: 40, count: 32))
        XCTAssertEqual(renewed.remotePairing?.privateKey, Data(repeating: 41, count: 32))
        XCTAssertTrue(renewed.hasLockdownRecord)
        XCTAssertNotEqual(renewed, record)
    }

    func testNewKeysAfterAFailedTunnelAreKeptOnlyIfTheIPhoneTookThem() throws {
        let record = try Sample.record(Sample.both)
        // Paired (the iPhone answered with its alt_irk), then the tunnel failed: the iPhone has the new keys.
        let paired = Sample.plist(Sample.remotePairing(key: 40))
        XCTAssertEqual(record.adoptingRemotePairing(from: paired, tunnelOpened: false)?.remotePairing?.privateKey,
                       Data(repeating: 41, count: 32))
        // Pairing broke off after idevice made new keys: nobody knows them, so the old ones stay.
        let abandoned = Sample.plist(Sample.remotePairing(key: 40, altIRK: nil))
        XCTAssertNil(record.adoptingRemotePairing(from: abandoned, tunnelOpened: false))
        // With the tunnel open, the iPhone accepted whatever is there.
        XCTAssertNotNil(record.adoptingRemotePairing(from: abandoned, tunnelOpened: true))
    }

    func testAdoptingRubbishChangesNothing() throws {
        let record = try Sample.record(Sample.both)
        XCTAssertNil(record.adoptingRemotePairing(from: Data("nope".utf8), tunnelOpened: true))
        XCTAssertNil(record.adoptingRemotePairing(from: Sample.plist(Sample.lockdown), tunnelOpened: true))
    }
}
