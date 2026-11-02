import Foundation
import NetworkExtension

/// Owns the VPN configuration and talks to the packet tunnel extension.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var vpnStatus: NEVPNStatus = .invalid
    @Published private(set) var status: TunnelStatus?
    @Published private(set) var peers: [String] = SharedStore().peers
    @Published var lastError: String?

    private let store = SharedStore()
    private var manager: NETunnelProviderManager?
    private var pollTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    var isConnected: Bool { vpnStatus == .connected }
    var isBusy: Bool { [.connecting, .disconnecting, .reasserting].contains(vpnStatus) }
    var displayAddress: String? { status?.address.nilIfEmpty ?? store.lastAddress }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first
            if let manager { observe(manager) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setConnected(_ on: Bool) async {
        lastError = nil
        do {
            if on {
                let manager = try await preparedManager()
                try manager.connection.startVPNTunnel()
            } else {
                manager?.connection.stopVPNTunnel()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addPeer(_ uri: String) async {
        let uri = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty, !peers.contains(uri) else { return }
        guard URL(string: uri)?.scheme.map(["tcp", "tls", "quic", "ws", "wss"].contains) == true else {
            lastError = "Peer URI must look like tls://host:port"
            return
        }
        peers.append(uri)
        store.peers = peers
        if isConnected { await send(.addPeer(uri)) }
    }

    func removePeer(_ uri: String) async {
        peers.removeAll { $0 == uri }
        store.peers = peers
        if isConnected { await send(.removePeer(uri)) }
    }

    func retryPeers() async { await send(.retryPeers) }

    // MARK: - ALFIS DNS

    @Published private(set) var dnsServers: [String] = SharedStore().dnsServers
    @Published private(set) var dnsTest: DNSTestResult?

    enum DNSTestResult: Equatable {
        case running
        case resolved(name: String, address: String, ms: Int)
        case failed(name: String, reason: String)
    }

    func addDNSServer(_ server: String) async {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard AlfisDNS.isValidServer(server) else {
            lastError = "DNS server must be a Yggdrasil IPv6 address (200::/7)"
            return
        }
        guard !dnsServers.contains(server) else { return }
        await setDNSServers(dnsServers + [server])
    }

    func removeDNSServer(_ server: String) async {
        await setDNSServers(dnsServers.filter { $0 != server })
    }

    func resetDNSServers() async { await setDNSServers(AlfisDNS.defaultServers) }

    private func setDNSServers(_ servers: [String]) async {
        dnsServers = servers
        store.dnsServers = servers
        if isConnected { await send(.reloadDNS) }
    }

    /// Resolves a known ALFIS name through the system resolver, which iOS routes
    /// to the tunnel's DNS servers because of matchDomains.
    func testDNS(name: String = AlfisDNS.testName) async {
        dnsTest = .running
        let start = Date()
        let result = await Task.detached { Self.resolveAAAA(name) }.value
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        switch result {
        case .success(let addr): dnsTest = .resolved(name: name, address: addr, ms: ms)
        case .failure(let err): dnsTest = .failed(name: name, reason: err.message)
        }
    }

    /// Per-server result of a direct UDP query (nil entry = probe running).
    @Published private(set) var dnsProbes: [String: DNSProbe.Outcome?] = [:]

    func probeDNSServers(name: String = AlfisDNS.testName) async {
        let servers = dnsServers
        dnsProbes = Dictionary(uniqueKeysWithValues: servers.map { ($0, nil) })
        await withTaskGroup(of: (String, DNSProbe.Outcome).self) { group in
            for s in servers {
                group.addTask { (s, await DNSProbe.query(server: s, name: name)) }
            }
            for await (s, outcome) in group { dnsProbes[s] = outcome }
        }
    }

    struct ResolveError: Error { let message: String }

    nonisolated private static func resolveAAAA(_ name: String) -> Result<String, ResolveError> {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(name, nil, &hints, &res)
        defer { if res != nil { freeaddrinfo(res) } }
        guard rc == 0, let ai = res, let sa = ai.pointee.ai_addr else {
            return .failure(ResolveError(message: String(cString: gai_strerror(rc))))
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
            var addr = sin6.pointee.sin6_addr
            _ = inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
        }
        return .success(String(cString: buf))
    }

    // MARK: - Private

    /// Creates the VPN profile on first use (this triggers the iOS "Add VPN Configuration" prompt).
    private func preparedManager() async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppIDs.tunnelBundleID
        proto.serverAddress = "Yggdrasil"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "YggApp"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences() // required before the first start
        if self.manager == nil { observe(manager) }
        self.manager = manager
        return manager
    }

    private func observe(_ manager: NETunnelProviderManager) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        vpnStatus = manager.connection.status
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.statusChanged() }
        }
        statusChanged()
    }

    private func statusChanged() {
        vpnStatus = manager?.connection.status ?? .invalid
        if isConnected {
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
            if vpnStatus == .disconnected { status = nil }
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.send(.status)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func send(_ request: TunnelRequest) async {
        guard let session = manager?.connection as? NETunnelProviderSession,
              let data = try? JSONEncoder().encode(request) else { return }
        let reply: Data? = await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(data) { cont.resume(returning: $0) }
            } catch {
                cont.resume(returning: nil)
            }
        }
        guard let reply, let decoded = try? JSONDecoder().decode(TunnelStatus.self, from: reply) else { return }
        status = decoded
        if let err = decoded.error { lastError = err }
    }
}

extension NEVPNStatus {
    var label: String {
        switch self {
        case .invalid: "Not configured"
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reasserting: "Reconnecting…"
        case .disconnecting: "Disconnecting…"
        @unknown default: "Unknown"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
