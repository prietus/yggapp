import Foundation
import NetworkExtension
import os

/// Turns the tunnel on/off. Shared by the app and the Control Center widget so
/// both apply the same On Demand rules.
enum VPNControl {
    static func loadManager() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first
    }

    /// Loads or creates the VPN profile and applies the current settings.
    /// Creating it the first time shows the iOS "Add VPN Configuration" prompt.
    static func preparedManager(existing: NETunnelProviderManager? = nil) async throws -> NETunnelProviderManager {
        let manager: NETunnelProviderManager
        if let existing {
            manager = existing
        } else {
            manager = try await loadManager() ?? NETunnelProviderManager()
        }
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppIDs.tunnelBundleID
        proto.serverAddress = "Yggdrasil"
        let store = SharedStore()
        var config = proto.providerConfiguration ?? [:]
        config[ProviderConfigKey.peers] = store.peers
        config[ProviderConfigKey.hosts] = store.alfisHostsJSON ?? "{}"
        proto.providerConfiguration = config
        // protocolConfiguration is a `copy` property: assign only after the
        // protocol is fully set up, or later changes to `proto` are lost.
        manager.protocolConfiguration = proto
        manager.localizedDescription = "YggApp"
        manager.isEnabled = true
        return manager
    }

    /// Connects or disconnects. With "connect automatically" on, connecting also
    /// arms On Demand so iOS brings the tunnel back on any network; disconnecting
    /// always disarms it, otherwise iOS would immediately reconnect.
    @discardableResult
    static func setEnabled(_ on: Bool, existing: NETunnelProviderManager? = nil) async throws -> NETunnelProviderManager {
        let manager = try await preparedManager(existing: existing)
        applyOnDemand(to: manager, enabled: on && SharedStore().autoConnect)
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences() // required before the first start
        let keys = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?.keys.sorted() ?? []
        Logger(subsystem: "com.prietus.yggapp", category: "vpn")
            .info("setEnabled(\(on)): profile saved, providerConfiguration keys \(keys.joined(separator: ","), privacy: .public)")
        if on {
            try manager.connection.startVPNTunnel()
        } else {
            manager.connection.stopVPNTunnel()
        }
        return manager
    }

    /// Re-applies On Demand after the user flips "connect automatically" while connected.
    static func updateOnDemand(_ manager: NETunnelProviderManager, tunnelOn: Bool) async throws {
        applyOnDemand(to: manager, enabled: tunnelOn && SharedStore().autoConnect)
        try await manager.saveToPreferences()
    }

    /// Persists the current peers/names into the profile so the extension sees
    /// them on its next start (including On Demand starts with no app running).
    static func saveProviderConfiguration(_ manager: NETunnelProviderManager) async throws {
        _ = try await preparedManager(existing: manager)
        try await manager.saveToPreferences()
    }

    static func isOn() async -> Bool {
        guard let manager = try? await loadManager() else { return false }
        return [.connected, .connecting, .reasserting].contains(manager.connection.status)
    }

    private static func applyOnDemand(to manager: NETunnelProviderManager, enabled: Bool) {
        let connect = NEOnDemandRuleConnect()
        connect.interfaceTypeMatch = .any
        manager.onDemandRules = [connect]
        manager.isOnDemandEnabled = enabled
    }
}
