import SwiftUI

@main
struct YggApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
                BrowserView()
                    .tabItem { Label("Browse", systemImage: "safari") }
            }
            .environmentObject(tunnel)
        }
    }
}
