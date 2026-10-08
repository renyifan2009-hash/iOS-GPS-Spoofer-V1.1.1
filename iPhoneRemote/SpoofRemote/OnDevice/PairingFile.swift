import Foundation
@preconcurrency import Security

/// This iPhone's lockdown pairing record, saved by the Mac app (File ▸ Save
/// iPhone Pairing File…) or `iosgpsspoof export-pairing`. It proves to the
/// iPhone that this app is a computer it trusts, so it lives in the Keychain,
/// on this device only, and isn't backed up.
struct PairingFile: Equatable, Sendable {
    let data: Data

    enum Problem: LocalizedError {
        case unreadable
        case notAPairingFile

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Couldn't open that file."
            case .notAPairingFile:
                "That isn't a pairing file. On your Mac, use File ▸ Save iPhone Pairing File… in iOS GPS Spoofer."
            }
        }
    }

    /// Keys every lockdown pairing record has.
    private static let requiredKeys = ["DeviceCertificate", "HostCertificate", "HostPrivateKey",
                                       "RootCertificate", "HostID", "SystemBUID"]

    init(data: Data) throws {
        guard let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Self.requiredKeys.allSatisfy({ record[$0] != nil }) else {
            throw Problem.notAPairingFile
        }
        self.data = data
    }

    /// A file from the Files app, AirDrop or "Open in".
    init(contentsOf url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw Problem.unreadable }
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

    @discardableResult
    func save() -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
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
