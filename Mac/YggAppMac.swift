import AppKit
import SwiftUI

/// Menu bar app: an icon with quick switches, plus a full options window.
@main
struct YggAppMac: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(app.tunnel)
                .environmentObject(app.systemExtension)
        } label: {
            MenuBarIcon(tunnel: app.tunnel)
        }
        .menuBarExtraStyle(.window)

        Window("YggApp", id: MainWindow.id) {
            ContentView()
                .environmentObject(app.tunnel)
                .frame(minWidth: 480, minHeight: 560)
        }
        .defaultSize(width: 520, height: 720)
        .windowResizability(.contentMinSize)
    }
}

enum MainWindow {
    static let id = "main"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tunnel = TunnelManager()
    let systemExtension = SystemExtensionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install/update the tunnel system extension (no-op when already current).
        systemExtension.activate()
        Task { await tunnel.load() }
    }
}

/// The status item: filled nodes while connected.
private struct MenuBarIcon: View {
    @ObservedObject var tunnel: TunnelManager

    var body: some View {
        Image(systemName: tunnel.isConnected
              ? "point.3.filled.connected.trianglepath.dotted"
              : "point.3.connected.trianglepath.dotted")
            .accessibilityLabel(tunnel.isConnected ? "YggApp, connected" : "YggApp, disconnected")
    }
}
