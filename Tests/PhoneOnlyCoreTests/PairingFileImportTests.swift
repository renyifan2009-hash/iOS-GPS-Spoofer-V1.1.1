import Foundation
import XCTest
@testable import PhoneOnlyCore

final class PairingFileImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairingFileImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Bounded read (PX-10)

    func testReadsAFileUnderTheLimit() throws {
        let url = folder.appendingPathComponent("small.mobiledevicepairing")
        try Data(repeating: 7, count: 10_000).write(to: url)
        XCTAssertEqual(try PairingFileImport.read(url).count, 10_000)
    }

    func testReadsAFileExactlyAtTheLimit() throws {
        let url = folder.appendingPathComponent("exact")
        try Data(repeating: 1, count: 64).write(to: url)
        XCTAssertEqual(try PairingFileImport.read(url, limit: 64).count, 64)
    }

    func testRefusesAFileOneByteOverTheLimit() throws {
        let url = folder.appendingPathComponent("over")
        try Data(repeating: 1, count: 65).write(to: url)
        XCTAssertThrowsError(try PairingFileImport.read(url, limit: 64)) {
            XCTAssertEqual($0 as? PairingFileImport.ReadError, .tooLarge)
        }
    }

    /// A multi-gigabyte file picked by mistake must be refused without being
    /// read. This one is sparse, so it costs no disk, and reading it whole
    /// would take seconds and gigabytes of memory.
    func testRefusesAHugeFileWithoutReadingIt() throws {
        let url = folder.appendingPathComponent("huge.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024)
        try handle.close()

        let start = Date()
        XCTAssertThrowsError(try PairingFileImport.read(url)) {
            XCTAssertEqual($0 as? PairingFileImport.ReadError, .tooLarge)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "should stop after the first megabyte")
    }

    func testAMissingFileAndAFolderAreUnreadable() throws {
        XCTAssertThrowsError(try PairingFileImport.read(folder.appendingPathComponent("nope"))) {
            XCTAssertEqual($0 as? PairingFileImport.ReadError, .unreadable)
        }
        XCTAssertThrowsError(try PairingFileImport.read(folder)) {
            XCTAssertEqual($0 as? PairingFileImport.ReadError, .unreadable)
        }
    }

    func testARealPairingFileIsFarUnderTheLimit() {
        // The sample files are about 10 KB.
        XCTAssertGreaterThan(PairingFileImport.maxBytes, 50 * 10_000)
    }

    // MARK: - The Inbox copy (PX-08, iphone-app-12)

    private func makeDocuments() throws -> (documents: URL, inbox: URL) {
        let documents = folder.appendingPathComponent("Documents", isDirectory: true)
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return (documents, inbox)
    }

    func testDeletesTheCopyInTheInbox() throws {
        let (documents, inbox) = try makeDocuments()
        let copy = inbox.appendingPathComponent("Samarth's iPhone.mobiledevicepairing")
        try Data("keys".utf8).write(to: copy)
        XCTAssertTrue(InboxCopy.discard(copy, documents: documents))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testNeverDeletesAFileThePersonPickedElsewhere() throws {
        let (documents, _) = try makeDocuments()
        let picked = folder.appendingPathComponent("Downloads/mine.mobiledevicepairing")
        try FileManager.default.createDirectory(at: picked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keys".utf8).write(to: picked)
        XCTAssertFalse(InboxCopy.discard(picked, documents: documents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
    }

    func testAFileDirectlyInDocumentsIsNotInTheInbox() throws {
        let (documents, _) = try makeDocuments()
        let file = documents.appendingPathComponent("notes.mobiledevicepairing")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(InboxCopy.discard(file, documents: documents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// "Inbox-old" starts with "Inbox" but is somebody else's folder.
    func testASiblingFolderWithTheSamePrefixIsNotTheInbox() throws {
        let (documents, _) = try makeDocuments()
        let sibling = documents.appendingPathComponent("Inbox-old", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let file = sibling.appendingPathComponent("a.mobiledevicepairing")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(InboxCopy.isInInbox(file, documents: documents))
        XCTAssertFalse(InboxCopy.discard(file, documents: documents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// `..` must not walk out of the Inbox into a file next to it.
    func testDotDotCannotEscapeTheInbox() throws {
        let (documents, inbox) = try makeDocuments()
        let outside = documents.appendingPathComponent("keep.mobiledevicepairing")
        try Data("x".utf8).write(to: outside)
        let sneaky = inbox.appendingPathComponent("../keep.mobiledevicepairing")
        XCTAssertFalse(InboxCopy.isInInbox(sneaky, documents: documents))
        XCTAssertFalse(InboxCopy.discard(sneaky, documents: documents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    /// The Inbox itself, or a folder inside it, is not "a copy".
    func testDoesNotRemoveFolders() throws {
        let (documents, inbox) = try makeDocuments()
        let inner = inbox.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        XCTAssertFalse(InboxCopy.discard(inbox, documents: documents))
        XCTAssertFalse(InboxCopy.discard(inner, documents: documents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inner.path))
    }

    /// A link in the Inbox that points outside must not get the target deleted.
    func testALinkOutOfTheInboxLeavesItsTarget() throws {
        let (documents, inbox) = try makeDocuments()
        let target = folder.appendingPathComponent("target.mobiledevicepairing")
        try Data("x".utf8).write(to: target)
        let link = inbox.appendingPathComponent("link.mobiledevicepairing")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(InboxCopy.discard(link, documents: documents))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testTheInboxIsFoundThroughSymbolicLinks() throws {
        let (documents, inbox) = try makeDocuments()
        let copy = inbox.appendingPathComponent("a.mobiledevicepairing")
        try Data("x".utf8).write(to: copy)
        // The same folder by a different route (on iOS, /var is /private/var).
        let alias = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents)
        let viaAlias = alias.appendingPathComponent("Inbox/a.mobiledevicepairing")
        XCTAssertTrue(InboxCopy.isInInbox(viaAlias, documents: documents))
        XCTAssertTrue(InboxCopy.discard(viaAlias, documents: documents))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testOnlyFileURLsAreDeleted() throws {
        let (documents, _) = try makeDocuments()
        XCTAssertFalse(InboxCopy.discard(URL(string: "https://example.com/Inbox/a")!, documents: documents))
    }

    func testSweepRemovesOnlyPairingFilesFromTheInbox() throws {
        let (documents, inbox) = try makeDocuments()
        try Data("a".utf8).write(to: inbox.appendingPathComponent("one.mobiledevicepairing"))
        try Data("b".utf8).write(to: inbox.appendingPathComponent("Two.MobileDevicePairing"))
        try Data("c".utf8).write(to: inbox.appendingPathComponent("photo.jpg"))
        let outside = documents.appendingPathComponent("three.mobiledevicepairing")
        try Data("d".utf8).write(to: outside)

        XCTAssertEqual(InboxCopy.discardPairingFiles(documents: documents), 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
        XCTAssertEqual(left, ["photo.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSweepWithNoInboxDoesNothing() {
        XCTAssertEqual(InboxCopy.discardPairingFiles(documents: folder.appendingPathComponent("none")), 0)
    }

    // MARK: - Where the file came from (PX-07)

    func testNameWithoutTheExtension() {
        XCTAssertEqual(PairingFileSource.displayName(fromFileName: "Samarth's iPhone.mobiledevicepairing"),
                       "Samarth's iPhone")
        XCTAssertEqual(PairingFileSource.displayName(fromFileName: "Phone.MobileDevicePairing"), "Phone")
        XCTAssertEqual(PairingFileSource.displayName(fromFileName: "iPhonePairing.plist"), "iPhonePairing")
        XCTAssertEqual(PairingFileSource.displayName(fromFileName: "no extension"), "no extension")
    }

    func testNameWithNothingToShowIsNil() {
        XCTAssertNil(PairingFileSource.displayName(fromFileName: ""))
        XCTAssertNil(PairingFileSource.displayName(fromFileName: "  .mobiledevicepairing"))
        XCTAssertNil(PairingFileSource.displayName(fromFileName: "\u{7}\u{8}"))
    }

    func testLongNamesAreShortened() throws {
        let name = try XCTUnwrap(PairingFileSource.displayName(fromFileName: String(repeating: "a", count: 200) + ".mobiledevicepairing"))
        XCTAssertEqual(name.count, 60)
        XCTAssertTrue(name.hasSuffix("…"))
    }

    func testSourceSurvivesBeingStored() throws {
        let source = PairingFileSource(fileName: "Samarth's iPhone.mobiledevicepairing",
                                       importedAt: Date(timeIntervalSince1970: 1_760_000_000))
        let data = try XCTUnwrap(source.attributeData)
        XCTAssertEqual(PairingFileSource(attributeData: data), source)
        XCTAssertNil(PairingFileSource(attributeData: Data("not json".utf8)))
    }

    func testSummaryNamesTheFileAndTheDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15)))

        func summary(_ fileName: String?, on date: Date) -> String {
            PairingFileSource(fileName: fileName, importedAt: date).summary(now: now, calendar: calendar, locale: locale)
        }
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9)))
        let lastYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 30, hour: 9)))
        XCTAssertEqual(summary("Sam's iPhone.mobiledevicepairing", on: earlier), "“Sam's iPhone”, added Oct 3")
        XCTAssertEqual(summary("Sam's iPhone.mobiledevicepairing", on: now), "“Sam's iPhone”, added today")
        XCTAssertEqual(summary(nil, on: earlier), "Added Oct 3")
        XCTAssertEqual(summary("Sam's iPhone.mobiledevicepairing", on: lastYear), "“Sam's iPhone”, added Dec 30, 2025")
    }
}
