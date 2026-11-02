import Foundation
import Security

/// Stores the node config (which contains the ed25519 private key) in the
/// extension's keychain. Only the tunnel extension ever reads it.
enum NodeKeychain {
    private static let service = "com.prietus.yggapp.node"
    private static let account = "config"

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let s):
                "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "unknown")"
            }
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// The tunnel may start on demand while the phone is locked, so the item
    /// must be readable after first unlock. It is included in encrypted backups
    /// so the node keeps its address when restoring to a new phone.
    static func save(_ config: String) throws {
        let data = Data(config.utf8)
        let update = [kSecValueData as String: data,
                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as [String: Any]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging(update) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}
