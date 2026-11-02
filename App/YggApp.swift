import SwiftUI

@main
struct YggApp: App {
    @StateObject private var tunnel = TunnelManager()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(tunnel)
        }
    }
}
