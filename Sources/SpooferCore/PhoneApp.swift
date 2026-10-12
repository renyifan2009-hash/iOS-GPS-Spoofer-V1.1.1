import CryptoKit
import Foundation
import PhoneOnlyCore

/// Getting the AnyWhere iPhone app (an `.ipa`) from the project's GitHub release, and making
/// sure it is the right file before it goes to the tool that signs it with the person's own
/// Apple ID (Sideloadly, AltStore, SideStore). Nothing here signs anything or touches an Apple
/// ID: signing needs Apple's own services and the person's credentials, so it stays with a tool
/// they trust (docs/design/iphone-standalone.md explains why).
public enum PhoneApp {
    /// Names the release may use for the iPhone app, newest first.
    public static let assetNames = ["AnyWhere.ipa", "SpoofRemote.ipa"]
    public static let checksumsName = "SHA256SUMS.txt"

    /// GitHub serves a release's file by name from this fixed address (no API call, so no rate limit).
    public static func downloadURL(asset: String, repository: String = Repository.slug) -> URL? {
        guard !asset.isEmpty, !asset.contains("/") else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/latest/download/\(asset)")
    }

    // MARK: Checksums

    /// The SHA-256 a `SHA256SUMS.txt` (`sha256sum` output: "<64 hex>  <name>") gives for `name`.
    public static func expectedChecksum(for name: String, inChecksumFile text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            // sha256sum marks binary files with a leading "*".
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            if (file as NSString).lastPathComponent == name { return hash }
        }
        return nil
    }

    /// The SHA-256 of a file, read in pieces (an `.ipa` is tens of megabytes).
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Looking inside an .ipa

    public struct Info: Equatable, Sendable {
        public let bundleID: String
        public let version: String
        public let build: String
        public let displayName: String

        public init(bundleID: String, version: String, build: String, displayName: String) {
            self.bundleID = bundleID
            self.version = version
            self.build = build
            self.displayName = displayName
        }
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notAZip
        case noApp
        case wrongApp(bundleID: String)
        case unreadable

        public var description: String {
            switch self {
            case .notAZip: return "That file isn't an iPhone app (it isn't a zip archive)."
            case .noApp: return "That file has no app inside it."
            case .wrongApp(let id): return "That is a different app (\(id)), not AnyWhere."
            case .unreadable: return "The app's information couldn't be read."
            }
        }
    }

    /// Reads `Payload/<name>.app/Info.plist` out of an `.ipa` without unpacking it to disk.
    public static func inspect(ipa url: URL) throws -> Info {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let listing = try ProcessRunner.run(unzip, arguments: ["-Z1", url.path], timeout: 60)
        guard listing.status == 0 else { throw Problem.notAZip }
        let entries = listing.stdout.split(whereSeparator: \.isNewline).map(String.init)
        // Exactly one level: Payload/Name.app/Info.plist (not a nested framework's plist).
        let plists = entries.filter {
            let parts = $0.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard let entry = plists.first else { throw Problem.noApp }
        // Info.plist in a built app is a binary plist, which can't be carried as text: extract the one
        // file into a private temporary folder and read its bytes.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("anywhere-ipa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let extracted = try ProcessRunner.run(unzip, arguments: ["-o", "-j", "-qq", url.path, entry, "-d", work.path], timeout: 60)
        guard extracted.status == 0,
              let data = try? Data(contentsOf: work.appendingPathComponent("Info.plist")),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = object as? [String: Any] else { throw Problem.unreadable }
        func string(_ key: String) -> String {
            if let value = info[key] as? String { return value }
            if let number = info[key] as? NSNumber { return number.stringValue }
            return ""
        }
        let bundleID = string("CFBundleIdentifier")
        guard !bundleID.isEmpty else { throw Problem.unreadable }
        return Info(bundleID: bundleID, version: string("CFBundleShortVersionString"), build: string("CFBundleVersion"),
                    displayName: string("CFBundleDisplayName").isEmpty ? string("CFBundleName") : string("CFBundleDisplayName"))
    }

    /// `inspect`, and the app has to be AnyWhere (the original bundle ID).
    @discardableResult
    public static func verify(ipa url: URL) throws -> Info {
        let info = try inspect(ipa: url)
        guard info.bundleID == SpoofRemote.bundleID else { throw Problem.wrongApp(bundleID: info.bundleID) }
        return info
    }

    // MARK: Signing tools the person may already have

    /// Where a Mac app is normally installed.
    public static var standardApplicationDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")]
    }

    public struct Sideloader: Equatable, Sendable {
        public let name: String
        public let appURL: URL

        public init(name: String, appURL: URL) {
            self.name = name
            self.appURL = appURL
        }
    }

    /// Mac apps that sign and install an `.ipa` with the person's own Apple ID.
    public static func installedSideloaders(in directories: [URL] = standardApplicationDirectories,
                                            fileManager fm: FileManager = .default) -> [Sideloader] {
        let known: [(String, [String])] = [
            ("Sideloadly", ["Sideloadly.app"]),
            ("AltStore", ["AltServer.app", "AltStore.app"]),
            ("SideStore", ["SideServer.app", "SideStore.app", "SideStore Installer.app"]),
        ]
        var found: [Sideloader] = []
        for (name, bundles) in known {
            for directory in directories {
                if let bundle = bundles.first(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                    found.append(Sideloader(name: name, appURL: directory.appendingPathComponent(bundle)))
                    break
                }
            }
        }
        return found
    }
}

