import Foundation
import SystemExtensions

/// Installs (or updates) the packet tunnel system extension. On first install
/// macOS asks the user to allow it in System Settings.
@MainActor
final class SystemExtensionManager: NSObject, ObservableObject {
    enum State: Equatable {
        case unknown
        case activating
        case needsApproval
        case active
        case failed(String)
    }

    @Published private(set) var state: State = .unknown

    var isReady: Bool { state == .active }
    var needsApproval: Bool { state == .needsApproval }
    var canRetry: Bool { if case .failed = state { true } else { false } }

    /// What to tell the user, or nil when everything is fine.
    var attentionMessage: String? {
        switch state {
        case .unknown, .active: nil
        case .activating: "Installing the YggApp network extension…"
        case .needsApproval: "Allow the YggApp network extension in System Settings → General → Login Items & Extensions."
        case .failed(let reason): reason
        }
    }

    func activate() {
        state = .activating
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: AppIDs.tunnelBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.state = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.state = result == .completed ? .active : .failed("Restart your Mac to finish installing the extension.")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        let message: String
        if ns.domain == OSSystemExtensionErrorDomain,
           ns.code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue {
            message = "Move YggApp to the Applications folder, then open it again."
        } else {
            message = "Couldn't install the network extension: \(ns.localizedDescription)"
        }
        Task { @MainActor in self.state = .failed(message) }
    }
}
