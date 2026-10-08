import Foundation
@preconcurrency import Security

/// Pairing tokens live in the Keychain, one item per paired Mac (keyed by the
/// Mac's server ID). They never leave this device and aren't backed up.
enum KeychainStore {
    private static let service = "com.iosgpsspoof.remote.token"

    private static func query(_ serverID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID,
        ]
    }

    @discardableResult
    static func save(token: String, for serverID: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(serverID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(serverID).merging(attributes) { _, new in new }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func token(for serverID: String) -> String? {
        var request = query(serverID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for serverID: String) {
        SecItemDelete(query(serverID) as CFDictionary)
    }
}
