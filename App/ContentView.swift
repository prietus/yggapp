import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var newPeer = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { tunnel.isConnected || tunnel.vpnStatus == .connecting },
                        set: { on in Task { await tunnel.setConnected(on) } }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Yggdrasil")
                            Text(tunnel.vpnStatus.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(tunnel.isBusy)

                    if let address = tunnel.displayAddress {
                        LabeledContent("Address") {
                            Text(address).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if let subnet = tunnel.status?.subnet.nilIfEmpty {
                        LabeledContent("Subnet") {
                            Text(subnet).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }

                Section("Peers") {
                    ForEach(tunnel.peers, id: \.self) { uri in
                        PeerRow(uri: uri, live: tunnel.status?.peers.first { $0.uri == uri })
                    }
                    .onDelete { idx in
                        let uris = idx.map { tunnel.peers[$0] }
                        Task { for u in uris { await tunnel.removePeer(u) } }
                    }
                    HStack {
                        TextField("tls://host:port", text: $newPeer)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.callout.monospaced())
                            .onSubmit(add)
                        Button("Add", action: add).disabled(newPeer.isEmpty)
                    }
                }

                let inbound = tunnel.status?.peers.filter { !tunnel.peers.contains($0.uri) } ?? []
                if !inbound.isEmpty {
                    Section("Other connections") {
                        ForEach(inbound) { PeerRow(uri: $0.uri.nilIfEmpty ?? $0.publicKey, live: $0) }
                    }
                }

                if let error = tunnel.lastError {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
            .navigationTitle("YggApp")
            .refreshable { await tunnel.retryPeers() }
        }
        .task { await tunnel.load() }
    }

    private func add() {
        let uri = newPeer
        newPeer = ""
        Task { await tunnel.addPeer(uri) }
    }
}

private struct PeerRow: View {
    let uri: String
    let live: PeerStatus?

    var body: some View {
        HStack {
            Circle()
                .fill(live == nil ? Color.gray : (live!.up ? .green : .orange))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(uri).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                if let live {
                    if live.up {
                        Text("\(Int(live.latencyMs)) ms · ↓\(bytes(live.rxBytes)) ↑\(bytes(live.txBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let err = live.lastError {
                        Text(err).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                }
            }
        }
    }

    private func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}
