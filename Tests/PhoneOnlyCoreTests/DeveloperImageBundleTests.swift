import CryptoKit
import Foundation
import XCTest
@testable import PhoneOnlyCore

final class DeveloperImageBundleTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func makeManifest(cryptex: Bool = false, path: String = "Image.dmg") throws {
        let keys = cryptex ? ["Cryptex1,GenericDmg", "Cryptex1,GenericTrustCache", "Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume"]
            : ["PersonalizedDMG", "LoadableTrustCache"]
        var entries: [String: Any] = [:]
        for (i, key) in keys.enumerated() {
            let payloadPath = i == 0 ? path : "payload-\(i)"
            let data = Data("fake test payload \(i)".utf8)
            if !payloadPath.contains("..") { try data.write(to: folder.appendingPathComponent(payloadPath)) }
            entries[key] = ["Info": ["Path": payloadPath], "Digest": Data(SHA384.hash(data: data))]
        }
        let manifest: [String: Any] = ["ProductBuildVersion": "TEST123", "BuildIdentities": [["Manifest": entries]]]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("BuildManifest.plist"))
    }

    func testImportValidatesAndCopiesOnlyPayloads() throws {
        try makeManifest()
        try Data("unrelated".utf8).write(to: folder.appendingPathComponent("ignore.txt"))
        let parent = folder.appendingPathComponent("stored")
        let image = try DeveloperImageBundle.importing(from: folder, into: parent)
        XCTAssertEqual(image.kind, .personalized)
        XCTAssertEqual(image.build, "TEST123")
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.directory.appendingPathComponent("ignore.txt").path))
        XCTAssertNoThrow(try DeveloperImageBundle(directory: image.directory))
    }

    func testCryptexPayloadsAreRetained() throws {
        try makeManifest(cryptex: true)
        let image = try DeveloperImageBundle(directory: folder)
        XCTAssertEqual(image.kind, .cryptex)
        XCTAssertEqual(image.payloadPaths.count, 4)
    }

    func testCombinedManifestWithMissingCryptexPayloadsUsesCompletePersonalizedSet() throws {
        try makeManifest()
        let url = folder.appendingPathComponent("BuildManifest.plist")
        var manifest = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        var identities = try XCTUnwrap(manifest["BuildIdentities"] as? [[String: Any]])
        let entry: [String: Any] = ["Info": ["Path": "not-in-this-folder"], "Digest": Data(repeating: 1, count: 48)]
        identities.append(["Manifest": Dictionary(uniqueKeysWithValues:
            ["Cryptex1,GenericDmg", "Cryptex1,GenericTrustCache", "Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume"].map { ($0, entry) })])
        manifest["BuildIdentities"] = identities
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: url)
        let image = try DeveloperImageBundle(directory: folder)
        XCTAssertEqual(image.kind, .personalized)
        XCTAssertNil(image.cryptexPaths)
        XCTAssertEqual(image.personalizedPaths, ["Image.dmg", "payload-1"])
    }

    func testChecksumMismatchIsRefusedBeforeImport() throws {
        try makeManifest()
        try Data("changed".utf8).write(to: folder.appendingPathComponent("Image.dmg"))
        let parent = folder.appendingPathComponent("stored")
        XCTAssertThrowsError(try DeveloperImageBundle.importing(from: folder, into: parent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }

    func testPathTraversalIsRefused() throws {
        try makeManifest(path: "../outside")
        XCTAssertThrowsError(try DeveloperImageBundle(directory: folder))
    }

    func testSymlinkIsRefused() throws {
        try makeManifest()
        let image = folder.appendingPathComponent("Image.dmg")
        try FileManager.default.moveItem(at: image, to: folder.appendingPathComponent("real-image"))
        try FileManager.default.createSymbolicLink(atPath: image.path, withDestinationPath: "real-image")
        XCTAssertThrowsError(try DeveloperImageBundle(directory: folder))
    }

    func testReadIsBoundedAndEmptyFilesAreRefused() throws {
        try Data(repeating: 0x01, count: 32).write(to: folder.appendingPathComponent("large"))
        XCTAssertThrowsError(try DeveloperImageBundle.read("large", in: folder, limit: 16))
        try Data().write(to: folder.appendingPathComponent("empty"))
        XCTAssertThrowsError(try DeveloperImageBundle.read("empty", in: folder, limit: 16))
    }
}
