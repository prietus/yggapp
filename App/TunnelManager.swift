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
