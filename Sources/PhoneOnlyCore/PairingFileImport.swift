import Foundation

/// How a pairing file gets from the Files app, AirDrop or Mail into the
/// iPhone app, and what is left behind afterwards. The rules live here, apart
/// from the screens, so they can be tested without an iPhone.
public enum PairingFileImport {
    /// The biggest file that is read at all. A real pairing file is about
    /// 10 KB, so this is around a hundred times that. Anything bigger can't be
    /// one, and the Files picker lets people choose any file.
    public static let maxBytes = 1_048_576

    public enum ReadError: Error, Equatable, Sendable {
        /// The file couldn't be opened or read.
        case unreadable
        /// More than `maxBytes`. Not read past the limit.
        case tooLarge
    }

    /// The file's bytes, or an error. It reads at most `limit + 1` bytes, so a
    /// huge file chosen by mistake is never loaded into memory. This also
    /// works when the file system can't say how big the file is.
    public static func read(_ url: URL, limit: Int = maxBytes) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ReadError.unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { throw ReadError.unreadable }
        guard data.count <= limit else { throw ReadError.tooLarge }
        return data
    }
}

/// The copy of a pairing file that iOS makes for the app.
///
/// The app doesn't open files in place, so AirDrop, Mail and "Open in" hand
/// it a copy in `Documents/Inbox`. That copy holds the same private keys as
/// the Keychain item, and the Inbox is part of the app's backup. Once the file
/// is safely in the Keychain, the copy is deleted.
///
/// Only files inside the Inbox are ever deleted. A file the person picked in
/// the Files app is theirs, and stays.
public enum InboxCopy {
    /// The folder iOS puts handed-over files in, inside the app's Documents.
    public static func inbox(in documents: URL) -> URL {
        documents.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Whether `url` is a file inside the Inbox. Symbolic links are followed
    /// first (`/var` is `/private/var`), and a folder that only starts with
    /// the same name (`Inbox-old`) doesn't count.
    public static func isInInbox(_ url: URL, documents: URL) -> Bool {
        let folder = inbox(in: documents).resolvingSymlinksInPath().standardizedFileURL.path
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        return file.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Delete the copy at `url` if it is a file in the Inbox. Returns whether
    /// it was deleted. Anything else is left alone.
    @discardableResult
    public static func discard(_ url: URL, documents: URL, fileManager: FileManager = .default) -> Bool {
        guard url.isFileURL, isInInbox(url, documents: documents) else { return false }
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return false }
        return (try? fileManager.removeItem(at: url)) != nil
    }

    /// Delete every pairing file left in the Inbox, such as one from an older
    /// version or from an import that failed. Returns how many were deleted.
    @discardableResult
    public static func discardPairingFiles(documents: URL, fileManager: FileManager = .default) -> Int {
        let folder = inbox(in: documents)
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var deleted = 0
        for name in names where name.lowercased().hasSuffix(".\(PairingFileSource.fileExtension)") {
            if discard(folder.appendingPathComponent(name), documents: documents, fileManager: fileManager) { deleted += 1 }
        }
        return deleted
    }
}

/// Where the pairing file on this iPhone came from: the name it had, and the
/// day it was added. Kept beside the file so the setup screen can say what the
/// iPhone holds. For showing only: nothing decides anything by it.
public struct PairingFileSource: Codable, Equatable, Sendable {
    /// What the Mac app and the command line name their files.
    public static let fileExtension = "mobiledevicepairing"

    /// The file's name without its extension, such as "Samarth's iPhone". Nil
    /// when it had none worth showing.
    public var name: String?
    public var importedAt: Date

    public init(fileName: String?, importedAt: Date) {
        self.name = fileName.flatMap(Self.displayName(fromFileName:))
        self.importedAt = importedAt
    }

    /// A file name as a plain name: no extension, no control characters, and
    /// not longer than a line is wide.
    public static func displayName(fromFileName fileName: String) -> String? {
        var name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        for ending in [".\(fileExtension)", ".plist"] where lower.hasSuffix(ending) {
            name = String(name.dropLast(ending.count))
            break
        }
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 60 { name = String(name.prefix(59)) + "…" }
        return name.isEmpty ? nil : name
    }

    // MARK: Keeping it

    /// The bytes stored beside the pairing file.
    public var attributeData: Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(self)
    }

    public init?(attributeData: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let source = try? decoder.decode(Self.self, from: attributeData) else { return nil }
        self = source
    }

    // MARK: Showing it

    /// For the setup screen: "“Samarth's iPhone”, added Oct 12", or just the
    /// day when the file had no name.
    public func summary(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let when = Self.day(importedAt, now: now, calendar: calendar, locale: locale)
        guard let name else { return "Added \(when)" }
        return "“\(name)”, added \(when)"
    }

    static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = style.month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }
}
