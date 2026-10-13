import CryptoKit
import Foundation

/// Apple developer-image files retained on the phone for a mount after reboot.
/// Apple still decides whether the image can be personalized for this device.
public struct DeveloperImageBundle: Sendable {
    public enum Kind: String, Sendable { case personalized, cryptex }
    public let directory: URL
    public let build: String
    public let kind: Kind
    public let payloadPaths: [String]
    public let personalizedPaths: [String]?
    public let cryptexPaths: [String]?

    public enum Problem: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let reason): "Can't use this developer image: \(reason)" }
        }
    }

    public static let maxImageBytes = 256 * 1024 * 1024
    public static let maxManifestBytes = 8 * 1024 * 1024
    private static let cryptexKeys = ["Cryptex1,GenericDmg", "Cryptex1,GenericTrustCache",
                                    "Cryptex1,CryptexInfoPlist", "Cryptex1,GenericVolume"]

    public init(directory: URL) throws {
        let manifestData = try Self.read("BuildManifest.plist", in: directory, limit: Self.maxManifestBytes)
        guard let manifest = try PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any],
              let build = manifest["ProductBuildVersion"] as? String, !build.isEmpty,
              let identities = manifest["BuildIdentities"] as? [[String: Any]] else {
            throw Problem.invalid("BuildManifest.plist is incomplete.")
        }
        let personalized = try Self.validateVariant(["PersonalizedDMG", "LoadableTrustCache"],
                                                    identities: identities, directory: directory)
        let cryptex = try Self.validateVariant(Self.cryptexKeys, identities: identities, directory: directory)
        guard personalized != nil || cryptex != nil else {
            throw Problem.invalid("The folder has no complete developer-image payload set. Copy all files named by the manifest.")
        }
        self.directory = directory
        self.build = build
        self.kind = cryptex == nil ? .personalized : .cryptex
        self.personalizedPaths = personalized
        self.cryptexPaths = cryptex
        self.payloadPaths = Array(Set((personalized ?? []) + (cryptex ?? []))).sorted()
    }

    /// A combined manifest may mention Cryptex files that aren't in a personalized-only folder.
    /// Missing sets are unavailable, not selected by their mere mention in the manifest.
    private static func validateVariant(_ keys: [String], identities: [[String: Any]], directory: URL) throws -> [String]? {
        guard let identity = identities.first(where: { identity in
            guard let entries = identity["Manifest"] as? [String: Any] else { return false }
            return keys.allSatisfy { entries[$0] != nil }
        }), let entries = identity["Manifest"] as? [String: Any] else { return nil }
        var specifications: [(String, Data)] = []
        for key in keys {
            guard let entry = entries[key] as? [String: Any], let info = entry["Info"] as? [String: Any],
                  let path = info["Path"] as? String, let digest = entry["Digest"] as? Data else {
                throw Problem.invalid("The manifest is incomplete for \(key).")
            }
            specifications.append((path, digest))
        }
        guard specifications.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.0).path) })
        else { return nil }
        var paths: [String] = []
        for (path, digest) in specifications {
            let payload = try Self.read(path, in: directory, limit: Self.maxImageBytes)
            guard !digest.isEmpty else {
                throw Problem.invalid("The manifest has no checksum for \(path).")
            }
            let actual: Data
            switch digest.count {
            case 20: actual = Data(Insecure.SHA1.hash(data: payload))
            case 32: actual = Data(SHA256.hash(data: payload))
            case 48: actual = Data(SHA384.hash(data: payload))
            default: throw Problem.invalid("Unknown checksum format for \(path).")
            }
            guard actual == digest else { throw Problem.invalid("\(path) doesn't match the manifest checksum.") }
            paths.append(path)
        }
        return paths
    }

    /// Copy only the validated payloads into a new, private directory. Failed imports never replace
    /// the currently selected image. Symlinks and paths that escape the selected folder are refused.
    public static func importing(from source: URL, into parent: URL) throws -> DeveloperImageBundle {
        let original = try DeveloperImageBundle(directory: source)
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        do {
            for path in ["BuildManifest.plist"] + Array(Set(original.payloadPaths)).sorted() {
                let target = destination.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source.appendingPathComponent(path), to: target)
            }
            // Validate the copy too, in case the source changed while it was being copied.
            return try DeveloperImageBundle(directory: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    public static func read(_ path: String, in directory: URL, limit: Int) throws -> Data {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Problem.invalid("A payload path leaves the selected folder.")
        }
        var file = directory
        for part in parts {
            file.appendPathComponent(String(part))
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Problem.invalid("Symbolic links aren't supported.") }
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= limit else {
            throw Problem.invalid("\(path) is missing, empty or too large.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw Problem.invalid("\(path) is empty or too large.") }
        return data
    }
}
