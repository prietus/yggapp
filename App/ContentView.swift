import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var newPeer = ""
    @State private var newDNS = ""

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

                DNSSection(newServer: $newDNS)

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

/// Split-DNS resolvers for ALFIS zones (.ygg, .anon, …) plus a live resolution test.
private struct DNSSection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Binding var newServer: String

    var body: some View {
        Section {
            ForEach(tunnel.dnsServers, id: \.self) { server in
                VStack(alignment: .leading, spacing: 2) {
                    Text(server).font(.callout.monospaced())
                    if let probe = tunnel.dnsProbes[server] {
                        if let outcome = probe {
                            Text(outcome.summary)
                                .font(.caption)
                                .foregroundStyle(outcome.reachable ? .green : .red)
                        } else {
                            Text("probing…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { idx in
                let servers = idx.map { tunnel.dnsServers[$0] }
                Task { for s in servers { await tunnel.removeDNSServer(s) } }
            }
            HStack {
                TextField("302:db60::53", text: $newServer)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .font(.callout.monospaced())
                    .onSubmit(add)
                Button("Add", action: add).disabled(newServer.isEmpty)
            }

            Button {
                Task { await tunnel.testDNS() }
            } label: {
                HStack {
                    Text("Test \(AlfisDNS.testName)")
                    Spacer()
                    testResult
                }
            }
            .disabled(!tunnel.isConnected || tunnel.dnsTest == .running)

            Button("Probe each server directly") {
                Task { await tunnel.probeDNSServers() }
            }
            .disabled(!tunnel.isConnected)

            if tunnel.dnsServers != AlfisDNS.defaultServers {
                Button("Restore default servers") { Task { await tunnel.resetDNSServers() } }
            }
        } header: {
            Text("DNS (.ygg)")
        } footer: {
            Text("Only \(AlfisDNS.zones.map { "." + $0 }.joined(separator: " ")) names are sent to these servers; all other lookups use your normal DNS.")
        }
    }

    @ViewBuilder private var testResult: some View {
        switch tunnel.dnsTest {
        case .none:
            EmptyView()
        case .running:
            ProgressView()
        case .resolved(_, let address, let ms):
            VStack(alignment: .trailing) {
                Text(address).font(.caption.monospaced()).foregroundStyle(.green)
                Text("\(ms) ms").font(.caption2).foregroundStyle(.secondary)
            }
        case .failed(_, let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func add() {
        let s = newServer
        newServer = ""
        Task { await tunnel.addDNSServer(s) }
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
