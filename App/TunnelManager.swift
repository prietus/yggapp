import Foundation
import NetworkExtension
import SwiftUI
#if os(iOS)
import WidgetKit
#endif

/// Owns the VPN configuration and talks to the packet tunnel extension.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var vpnStatus: NEVPNStatus = .invalid
    @Published private(set) var status: TunnelStatus?
    @Published private(set) var peers: [String] = SharedStore().peers
    @Published var lastError: String?
    @Published private(set) var autoConnect: Bool = SharedStore().autoConnect

    private let store = SharedStore()
    private var manager: NETunnelProviderManager?
    private var pollTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?

    var isConnected: Bool { vpnStatus == .connected }
    var isBusy: Bool { [.connecting, .disconnecting, .reasserting].contains(vpnStatus) }
    var displayAddress: String? { status?.address.nilIfEmpty ?? store.lastAddress }

    func load() async {
        do {
            manager = try await VPNControl.loadManager()
            if let manager { observe(manager) }
        } catch {
            lastError = error.localizedDescription
        }
        // The Control Center widget edits the same profile from another process.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNConfigurationChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.load() }
            }
        }
    }

    func setConnected(_ on: Bool) async {
        lastError = nil
        do {
            let m = try await VPNControl.setEnabled(on, existing: manager)
            if manager !== m {
                manager = m
                observe(m)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "Connect automatically": iOS keeps the tunnel up on any network (On Demand).
    func setAutoConnect(_ on: Bool) async {
        autoConnect = on
        store.autoConnect = on
        guard let manager else { return }
        do {
            try await VPNControl.updateOnDemand(manager, tunnelOn: isConnected || vpnStatus == .connecting)
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
        await persistProviderConfiguration()
        if isConnected { await send(.addPeer(uri)) }
    }

    func removePeer(_ uri: String) async {
        peers.removeAll { $0 == uri }
        store.peers = peers
        await persistProviderConfiguration()
        if isConnected { await send(.removePeer(uri)) }
    }

    func retryPeers() async { await send(.retryPeers) }

    // MARK: - ALFIS DNS (local resolver fed from the web directory)

    @Published private(set) var hostsUpdated: Date? = SharedStore().alfisHostsUpdated
    @Published private(set) var hostsCount: Int = SharedStore.hostsCount()
    @Published private(set) var isSyncingHosts = false
    @Published private(set) var dnsTest: DNSTestResult?

    enum DNSTestResult: Equatable {
        case running
        /// `system`: through iOS (proves split DNS); `direct`: raw query to the local resolver.
        case done(system: Result<String, ResolveError>, direct: DNSProbe.Outcome?, ms: Int)
    }

    /// Downloads the directory over the tunnel and hands the table to the extension.
    func syncHosts() async {
        guard isConnected, !isSyncingHosts else { return }
        isSyncingHosts = true
        defer { isSyncingHosts = false }
        do {
            let result = try await DirectorySync.fetch()
            let json = try JSONSerialization.data(withJSONObject: result.hosts, options: [.sortedKeys])
            store.alfisHostsJSON = String(decoding: json, as: UTF8.self)
            store.alfisHostsUpdated = Date()
            hostsUpdated = store.alfisHostsUpdated
            hostsCount = result.hosts.count
            await persistProviderConfiguration()
            await send(.setHosts(store.alfisHostsJSON ?? "{}"))
        } catch {
            lastError = "Directory sync: \(error.localizedDescription)"
        }
    }

    /// Called whenever the tunnel comes up: refresh the table if missing or stale.
    private func syncHostsIfStale() {
        let stale = hostsUpdated.map { Date().timeIntervalSince($0) > AlfisDNS.refreshInterval } ?? true
        if stale || hostsCount == 0 { Task { await syncHosts() } }
    }

    func testDNS(name: String = AlfisDNS.testName) async {
        dnsTest = .running
        let start = Date()
        async let system = Task.detached { Self.resolveAAAA(name) }.value
        let dnsAddress = status?.dnsAddress ?? ""
        async let direct: DNSProbe.Outcome? = dnsAddress.isEmpty ? nil : DNSProbe.query(server: dnsAddress, name: name)
        let (s, d) = await (system, direct)
        dnsTest = .done(system: s, direct: d, ms: Int(Date().timeIntervalSince(start) * 1000))
    }

    struct ResolveError: Error, Equatable { let message: String }

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

    /// The extension reads peers/names from the VPN profile at start (the macOS
    /// system extension can't see SharedStore), so keep the profile current.
    private func persistProviderConfiguration() async {
        guard let manager else { return }
        do {
            try await VPNControl.saveProviderConfiguration(manager)
        } catch {
            lastError = error.localizedDescription
        }
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
        #if os(iOS)
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: AppIDs.controlKind)
        }
        #endif
        if isConnected {
            startPolling()
            syncHostsIfStale()
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
        if !decoded.address.isEmpty { store.lastAddress = decoded.address }
        if let err = decoded.error { lastError = err }
    }
}

/// What the user cares about: is the node actually on the network?
enum NetworkState: Equatable {
    case tunnel(NEVPNStatus)   // VPN not up yet (off, connecting, …)
    case starting              // tunnel up, no status from the extension yet
    case noPeers
    case connectingPeers(configured: Int)
    case online(peersUp: Int, routes: Int)

    var label: String {
        switch self {
        case .tunnel(let s): s.label
        case .starting: "Starting…"
        case .noPeers: "No peers — add one below"
        case .connectingPeers(let n): "Connecting to \(n) peer\(n == 1 ? "" : "s")…"
        case .online(let up, let routes):
            "Online · \(up) peer\(up == 1 ? "" : "s") · \(routes) route\(routes == 1 ? "" : "s")"
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .noPeers, .connectingPeers, .starting: .orange
        case .tunnel(let s): [.connecting, .reasserting].contains(s) ? .orange : .gray
        }
    }
}

extension TunnelManager {
    var networkState: NetworkState {
        guard isConnected else { return .tunnel(vpnStatus) }
        guard let status else { return .starting }
        let up = status.peers.filter(\.up).count
        if up > 0 { return .online(peersUp: up, routes: status.routingEntries) }
        return peers.isEmpty ? .noPeers : .connectingPeers(configured: peers.count)
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

extension SharedStore {
    static func hostsCount() -> Int {
        guard let json = SharedStore().alfisHostsJSON,
              let dict = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        else { return 0 }
        return dict.count
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
