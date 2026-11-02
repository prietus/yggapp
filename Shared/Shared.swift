import Foundation

/// Identifiers shared by the app and the packet tunnel extension.
enum AppIDs {
    static let appGroup = "group.com.prietus.yggapp"
    static let tunnelBundleID = "com.prietus.yggapp.tunnel"
}

/// ALFIS (blockchain DNS) zones. Only queries for these go to the Yggdrasil
/// resolvers; everything else keeps using the system DNS.
enum AlfisDNS {
    static let zones = ["ygg", "anon", "btn", "conf", "index", "merch", "mirror", "mob", "screen", "srv"]

    /// Community resolvers published for ALFIS (2021–22 sources); user-editable
    /// because there is no current official list.
    static let defaultServers = ["302:db60::53", "302:7991::53", "300:6223::53"]

    /// Known-good name from the Yggdrasil web directory, used by the DNS test.
    static let testName = "forum.ygg"

    static func isValidServer(_ s: String) -> Bool {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, s, &addr) == 1 else { return false }
        // Must be inside 200::/7, i.e. reachable through the tunnel.
        return addr.__u6_addr.__u6_addr8.0 & 0xFE == 0x02
    }
}

/// App ↔ extension messages (sent with NETunnelProviderSession.sendProviderMessage).
enum TunnelRequest: Codable {
    case status
    case addPeer(String)
    case removePeer(String)
    case retryPeers
    /// Re-applies tunnel network settings after the DNS server list changed.
    case reloadDNS
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

    var dnsServers: [String] {
        get { defaults.stringArray(forKey: "dnsServers") ?? AlfisDNS.defaultServers }
        nonmutating set { defaults.set(newValue, forKey: "dnsServers") }
    }

    /// Last known address, so the app can show it while disconnected.
    var lastAddress: String? {
        get { defaults.string(forKey: "lastAddress") }
        nonmutating set { defaults.set(newValue, forKey: "lastAddress") }
    }
}
