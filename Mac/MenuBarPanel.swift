import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon: the same switches as the
/// top of the iOS Network tab, a peer summary, and a way into the full window.
struct MenuBarPanel: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var systemExtension: SystemExtensionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let message = systemExtension.attentionMessage {
                extensionBanner(message)
            }

            Divider()

            Toggle("Connect automatically", isOn: Binding(
                get: { tunnel.autoConnect },
                set: { on in Task { await tunnel.setAutoConnect(on) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if let address = tunnel.displayAddress {
                addressRow(address)
            }

            if let peers = tunnel.status?.peers, !peers.isEmpty {
                peerSummary(peers)
            }

            if let error = tunnel.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuRowButton(title: "Open YggApp…", systemImage: "macwindow") {
                    openWindow(id: MainWindow.id)
                    NSApp.activate()
                }
                MenuRowButton(title: "Quit YggApp", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(tunnel.networkState.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Yggdrasil").font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(tunnel.networkState.color).frame(width: 7, height: 7)
                    Text(tunnel.networkState.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Yggdrasil", isOn: Binding(
                get: { tunnel.isConnected || tunnel.vpnStatus == .connecting },
                set: { on in Task { await tunnel.setConnected(on) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(tunnel.isBusy || !systemExtension.isReady)
        }
    }

    private func addressRow(_ address: String) -> some View {
        HStack {
            Text("Address").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(address)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy address")
        }
    }

    private func peerSummary(_ peers: [PeerStatus]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Peers").font(.caption).foregroundStyle(.secondary)
            ForEach(peers.prefix(5)) { peer in
                HStack(spacing: 6) {
                    Circle().fill(peer.up ? Color.green : .orange).frame(width: 6, height: 6)
                    Text(URL(string: peer.uri)?.host ?? peer.uri)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if peer.up {
                        Text("\(Int(peer.latencyMs)) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if peers.count > 5 {
                Text("+\(peers.count - 5) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func extensionBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if systemExtension.needsApproval {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                .controlSize(.small)
            } else if systemExtension.canRetry {
                Button("Try Again") { systemExtension.activate() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A full-width, menu-like row button with hover highlight.
private struct MenuRowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
