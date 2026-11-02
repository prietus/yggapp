import NetworkExtension
import os
import Yggkit

private let log = Logger(subsystem: "com.prietus.yggapp", category: "tunnel")

/// Forwards Yggdrasil core logs to the unified log (Console.app → subsystem filter).
private final class CoreLogger: NSObject, YggkitLoggerProtocol {
    func log(_ line: String?) {
        guard let line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return }
        os.Logger(subsystem: "com.prietus.yggapp", category: "core").info("\(line, privacy: .public)")
    }
}

enum TunnelError: LocalizedError {
    case utunNotFound
    case config(String)

    var errorDescription: String? {
        switch self {
        case .utunNotFound: "Could not find the utun file descriptor"
        case .config(let msg): "Config error: \(msg)"
        }
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let node = YggkitNewNode()!
    private let coreLogger = CoreLogger()
    private let store = SharedStore()

    override func startTunnel(options: [String: NSObject]?) async throws {
        let config = try loadConfig(withPeers: store.peers)
        try node.start(config, logger: coreLogger)
        reloadHosts()

        let address = node.address()
        store.lastAddress = address
        log.info("node up at \(address, privacy: .public), mtu \(self.node.mtu())")

        do {
            try await setTunnelNetworkSettings(networkSettings())
            let fd = ygg_find_utun_fd()
            guard fd >= 0 else { throw TunnelError.utunNotFound }
            try node.attachTUN(fd)
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            try? node.stop()
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.info("stopping, reason \(reason.rawValue)")
        try? node.stop()
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let response: TunnelStatus
        do {
            let request = try JSONDecoder().decode(TunnelRequest.self, from: messageData)
            switch request {
            case .status: break
            case .addPeer(let uri): try node.addPeer(uri)
            case .removePeer(let uri): try node.removePeer(uri)
            case .retryPeers: node.retryPeers()
            case .reloadHosts: reloadHosts()
            }
            response = status()
        } catch {
            var s = status()
            s.error = error.localizedDescription
            response = s
        }
        return try? JSONEncoder().encode(response)
    }

    // MARK: - Helpers

    /// Routes 200::/7 into the tunnel and sends only ALFIS zones to the Yggdrasil resolvers.
    private func networkSettings() -> NEPacketTunnelNetworkSettings {
        // 200::/7 covers node addresses (200::/8) and routed /64 subnets (300::/8).
        let ipv6 = NEIPv6Settings(addresses: [node.address()], networkPrefixLengths: [7])
        ipv6.includedRoutes = [NEIPv6Route(destinationAddress: "200::", networkPrefixLength: 7)]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "::1")
        settings.ipv6Settings = ipv6
        settings.mtu = NSNumber(value: node.mtu())

        // yggkit answers <subnet>::53 itself from the local name table.
        let dnsAddress = node.dnsAddress()
        let dns = NEDNSSettings(servers: [dnsAddress])
        dns.matchDomains = AlfisDNS.zones   // split DNS: only these zones
        dns.matchDomainsNoSearch = true     // don't append them as search suffixes
        settings.dnsSettings = dns
        log.info("dns: \(dnsAddress, privacy: .public) for \(AlfisDNS.zones.count) zones")
        return settings
    }

    private func reloadHosts() {
        do {
            try node.setHostsJSON(store.alfisHostsJSON ?? "{}")
            log.info("hosts: \(self.node.hostCount()) names loaded")
        } catch {
            log.error("hosts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func status() -> TunnelStatus {
        let peers = (try? JSONDecoder().decode([PeerStatus].self, from: Data(node.peersJSON().utf8))) ?? []
        return TunnelStatus(address: node.address(), subnet: node.subnet(),
                            publicKey: node.publicKey(), peers: peers,
                            dnsAddress: node.dnsAddress(), hostCount: node.hostCount(),
                            routingEntries: node.routingEntries())
    }

    /// Loads (or creates on first run) the node config and injects the saved peers.
    private func loadConfig(withPeers peers: [String]) throws -> String {
        var json = store.configJSON
        if json == nil {
            var err: NSError?
            let generated = YggkitGenerateConfig(&err)
            if let err { throw TunnelError.config(err.localizedDescription) }
            store.configJSON = generated
            json = generated
        }
        guard let data = json?.data(using: .utf8),
              var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TunnelError.config("stored config is not a JSON object")
        }
        dict["Peers"] = peers
        let merged = try JSONSerialization.data(withJSONObject: dict)
        return String(decoding: merged, as: UTF8.self)
    }
}
