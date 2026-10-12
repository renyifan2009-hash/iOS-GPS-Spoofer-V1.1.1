import Foundation
import PhoneOnlyCore
@preconcurrency import Security

/// This iPhone's pairing file, made by the Mac app (File ▸ Pairing File for the
/// iPhone App…) or `iosgpsspoof export-pairing`. It proves to the iPhone
/// that this app is a computer it trusts, so it lives in the Keychain, on this
/// device only, and isn't backed up. `PairingRecord` has the format.
///
/// AirDrop and Mail hand the app a copy of the file in its Inbox folder. Once
/// the Keychain has the file, `OnDeviceController` deletes that copy.
struct PairingFile: Equatable, Sendable {
    let record: PairingRecord

    var data: Data { record.data }

    enum Problem: LocalizedError, Equatable {
        /// The file couldn't be opened or read.
        case unreadable
        /// Far bigger than any pairing file.
        case tooLarge
        /// Not a property list, the format pairing files are saved in.
        case notAPropertyList
        /// A property list, but with no complete pairing in it.
        case noIdentity

        private static let menu = "File ▸ Pairing File for the iPhone App…"

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Couldn't open that file. If it is in iCloud Drive, open the Files app and let it download first. Then try again."
            case .tooLarge:
                "That file is far too big to be a pairing file. On your Mac, open AnyWhere and choose \(Self.menu)"
            case .notAPropertyList:
                "That isn't a pairing file. On your Mac, open AnyWhere and choose \(Self.menu)"
            case .noIdentity:
                "That file doesn't hold a complete pairing. Plug this iPhone into your Mac, unlock it and tap Trust. "
                    + "Then open AnyWhere there and choose \(Self.menu)"
            }
        }

        /// The file was read and turned down for what it holds. A copy of it
        /// in the Inbox is no use to anyone, so it can go.
        var rejectsTheFile: Bool {
            switch self {
            case .tooLarge, .notAPropertyList, .noIdentity: true
            case .unreadable: false
            }
        }
    }

    init(record: PairingRecord) {
        self.record = record
    }

    init(data: Data) throws {
        do {
            record = try PairingRecord(data: data)
        } catch PairingRecord.Problem.notAPropertyList {
            throw Problem.notAPropertyList
        } catch {
            throw Problem.noIdentity
        }
    }

    /// A file from the Files app, AirDrop or "Open in". Reads at most
    /// `PairingFileImport.maxBytes`: the picker allows any file, and a huge
    /// one must not be loaded into memory.
    init(contentsOf url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try PairingFileImport.read(url)
        } catch PairingFileImport.ReadError.tooLarge {
            throw Problem.tooLarge
        } catch {
            throw Problem.unreadable
        }
        try self.init(data: data)
    }

    // MARK: - Keychain

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.iosgpsspoof.remote.pairing-file",
            kSecAttrAccount as String: "this-iphone",
        ]
    }

    static func load() -> PairingFile? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? PairingFile(data: data)
    }

    /// Where the stored file came from (its name and the day it was added), if
    /// that was kept. A file stored by an older version has none.
    static func loadSource() -> PairingFileSource? {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let data = attributes[kSecAttrGeneric as String] as? Data else { return nil }
        return PairingFileSource(attributeData: data)
    }

    /// Keep the file in the Keychain. With a `source`, also keep where it came
    /// from, beside it. Without one, the source already stored stays as it was
    /// (a renewed file is still the same file to the person).
    @discardableResult
    func save(source: PairingFileSource? = nil) -> Bool {
        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let sourceData = source?.attributeData { attributes[kSecAttrGeneric as String] = sourceData }
        let status = SecItemUpdate(Self.query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = Self.query.merging(attributes) { _, new in new }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
