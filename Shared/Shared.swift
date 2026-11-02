import Foundation

/// Identifiers shared by the app and the packet tunnel extension.
enum AppIDs {
    static let appGroup = "group.com.prietus.yggapp"
    static let tunnelBundleID = "com.prietus.yggapp.tunnel"
}

/// ALFIS (blockchain DNS) zones. Only queries for these go to the in-tunnel
/// resolver (answered by yggkit); everything else keeps using the system DNS.
/// The published community ALFIS resolvers were all dead as of 2026-11-02.
enum AlfisDNS {
    static let zones = ["ygg", "anon", "btn", "conf", "index", "merch", "mirror", "mob", "screen", "srv"]

    /// Yggdrasil Web directory; its "Domain name (ALFIS)" column seeds the name table.
    static let directoryURL = URL(string: "http://[21e:a51c:885b:7db0:166e:927:98cd:d186]/")!

    /// Re-download the directory when the table is older than this.
    static let refreshInterval: TimeInterval = 24 * 3600

    /// Known name from the directory, used by the DNS test.
    static let testName = "forum.ygg"
}

/// App ↔ extension messages (sent with NETunnelProviderSession.sendProviderMessage).
enum TunnelRequest: Codable {
    case status
    case addPeer(String)
    case removePeer(String)
    case retryPeers
    /// Reload the name table from SharedStore.alfisHostsJSON.
    case reloadHosts
}

struct TunnelStatus: Codable, Equatable {
    var address: String
    var subnet: String
    var publicKey: String
    var peers: [PeerStatus]
    var dnsAddress: String
    var hostCount: Int
    var routingEntries: Int
    var memory: MemoryStats
    var error: String?
}

/// Network extension memory, in bytes. iOS kills packet tunnels at ~50 MB footprint.
struct MemoryStats: Codable, Equatable {
    static let limit: UInt64 = 50 << 20

    var footprint: UInt64       // phys_footprint: what jetsam measures
    var peakFootprint: UInt64   // highest footprint seen since the tunnel started
    var goTotal: Int64          // all memory mapped by the Go runtime
    var goHeap: Int64           // live + unswept Go heap objects
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
/// The node config (private key) is NOT here: it lives in the extension's
/// keychain (NodeKeychain). `configJSON` only exists to migrate old installs.
struct SharedStore {
    private let defaults = UserDefaults(suiteName: AppIDs.appGroup)!

    var peers: [String] {
        get { defaults.stringArray(forKey: "peers") ?? [] }
        nonmutating set { defaults.set(newValue, forKey: "peers") }
    }

    /// Legacy location of the node config; read once and cleared by the extension.
    var configJSON: String? {
        get { defaults.string(forKey: "configJSON") }
        nonmutating set { defaults.set(newValue, forKey: "configJSON") }
    }

    /// {"forum.ygg": "21a:…", …} built from the web directory.
    var alfisHostsJSON: String? {
        get { defaults.string(forKey: "alfisHosts") }
        nonmutating set { defaults.set(newValue, forKey: "alfisHosts") }
    }

    var alfisHostsUpdated: Date? {
        get { defaults.object(forKey: "alfisHostsUpdated") as? Date }
        nonmutating set { defaults.set(newValue, forKey: "alfisHostsUpdated") }
    }

    /// Last known address, so the app can show it while disconnected.
    var lastAddress: String? {
        get { defaults.string(forKey: "lastAddress") }
        nonmutating set { defaults.set(newValue, forKey: "lastAddress") }
    }
}
