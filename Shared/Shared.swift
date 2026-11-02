import Foundation

/// Identifiers shared by the app and the packet tunnel extension.
enum AppIDs {
    static let appGroup = "group.com.prietus.yggapp"
    static let tunnelBundleID = "com.prietus.yggapp.tunnel"
}

/// App ↔ extension messages (sent with NETunnelProviderSession.sendProviderMessage).
enum TunnelRequest: Codable {
    case status
    case addPeer(String)
    case removePeer(String)
    case retryPeers
}

struct TunnelStatus: Codable, Equatable {
    var address: String
    var subnet: String
    var publicKey: String
    var peers: [PeerStatus]
    var error: String?
}

struct PeerStatus: Codable, Equatable, Identifiable {
    var id: String { uri.isEmpty ? publicKey : uri }
    var uri: String
    var up: Bool
    var inbound: Bool
    var address: String?
    var publicKey: String
    var latencyMs: Double
    var uptimeS: Double
    var rxBytes: UInt64
    var txBytes: UInt64
    var lastError: String?
}

/// State persisted in the App Group so both processes see it.
/// Spike note: the node config (with its private key) lives in App Group
/// defaults; move it to a shared Keychain item before shipping.
struct SharedStore {
    private let defaults = UserDefaults(suiteName: AppIDs.appGroup)!

    var peers: [String] {
        get { defaults.stringArray(forKey: "peers") ?? [] }
        nonmutating set { defaults.set(newValue, forKey: "peers") }
    }

    var configJSON: String? {
        get { defaults.string(forKey: "configJSON") }
        nonmutating set { defaults.set(newValue, forKey: "configJSON") }
    }

    /// Last known address, so the app can show it while disconnected.
    var lastAddress: String? {
        get { defaults.string(forKey: "lastAddress") }
        nonmutating set { defaults.set(newValue, forKey: "lastAddress") }
    }
}
