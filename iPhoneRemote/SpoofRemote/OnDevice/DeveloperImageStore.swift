import Foundation
import PhoneOnlyCore

/// Only Apple image payloads are stored here. Pairing secrets stay in the Keychain.
enum DeveloperImageStore {
    private static let key = "standaloneDeveloperImage"
    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeveloperImages", isDirectory: true)
    }

    static var directory: URL? {
        guard let name = UserDefaults.standard.string(forKey: key), UUID(uuidString: name) != nil else { return nil }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    static func importFolder(_ url: URL) throws -> DeveloperImageBundle {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bundle = try DeveloperImageBundle.importing(from: url, into: root)
        var stored = bundle.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try stored.setResourceValues(values)
        let previous = directory
        UserDefaults.standard.set(bundle.directory.lastPathComponent, forKey: key)
        if let previous, previous != bundle.directory { try? FileManager.default.removeItem(at: previous) }
        return bundle
    }
}
