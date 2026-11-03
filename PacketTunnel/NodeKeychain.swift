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

    #if os(macOS)
    // The macOS tunnel is a system extension running as root, where the login
    // keychain isn't available. Keep the config in its sandbox container,
    // readable by root only.
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YggApp", isDirectory: true)
        return dir.appendingPathComponent("node-config.json")
    }

    static func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    static func save(_ config: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try Data(config.utf8).write(to: fileURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    #else
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
    #endif
}
