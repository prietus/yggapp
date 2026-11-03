import Foundation
import NetworkExtension

// Entry point of the macOS packet tunnel system extension. The provider class
// (PacketTunnelProvider, shared with iOS) is named in Info.plist.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
