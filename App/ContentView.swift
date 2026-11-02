import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var newPeer = ""
    @State private var showPublicPeers = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { tunnel.isConnected || tunnel.vpnStatus == .connecting },
                        set: { on in Task { await tunnel.setConnected(on) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Yggdrasil")
                            let state = tunnel.networkState
                            HStack(spacing: 6) {
                                Circle().fill(state.color).frame(width: 7, height: 7)
                                Text(state.label).font(.caption).foregroundStyle(.secondary)
                            }
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
                    Button {
                        showPublicPeers = true
                    } label: {
                        Label("Browse public peers", systemImage: "globe.europe.africa")
                    }
                }

                DNSSection()

                if let memory = tunnel.status?.memory {
                    MemorySection(memory: memory)
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
            .sheet(isPresented: $showPublicPeers) { PublicPeersView() }
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

/// Local resolver for ALFIS zones (.ygg, .anon, …) fed from the web directory.
private struct DNSSection: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        Section {
            if let addr = tunnel.status?.dnsAddress.nilIfEmpty {
                LabeledContent("Resolver") {
                    Text(addr).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            LabeledContent("Names") {
                VStack(alignment: .trailing) {
                    Text("\(tunnel.hostsCount)")
                    if let updated = tunnel.hostsUpdated {
                        Text(updated, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                Task { await tunnel.syncHosts() }
            } label: {
                HStack {
                    Text("Update from directory")
                    Spacer()
                    if tunnel.isSyncingHosts { ProgressView() }
                }
            }
            .disabled(!tunnel.isConnected || tunnel.isSyncingHosts)

            Button {
                Task { await tunnel.testDNS() }
            } label: {
                HStack(alignment: .top) {
                    Text("Test \(AlfisDNS.testName)")
                    Spacer()
                    testResult
                }
            }
            .disabled(!tunnel.isConnected || tunnel.dnsTest == .running)
        } header: {
            Text("DNS (.ygg)")
        } footer: {
            Text("Names come from the Yggdrasil Web directory and are answered inside the app. Only \(AlfisDNS.zones.map { "." + $0 }.joined(separator: " ")) lookups use it; everything else uses your normal DNS.")
        }
    }

    @ViewBuilder private var testResult: some View {
        switch tunnel.dnsTest {
        case .none:
            EmptyView()
        case .running:
            ProgressView()
        case .done(let system, let direct, let ms):
            VStack(alignment: .trailing, spacing: 2) {
                switch system {
                case .success(let addr):
                    Text(addr).font(.caption.monospaced()).foregroundStyle(.green)
                case .failure(let err):
                    Text("iOS: \(err.message)").font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                if let direct {
                    Text("direct: \(direct.summary)").font(.caption2)
                        .foregroundStyle(direct.reachable ? Color.secondary : Color.red)
                }
                Text("\(ms) ms").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Live memory of the tunnel extension against the ~50 MB jetsam limit.
private struct MemorySection: View {
    let memory: MemoryStats

    var body: some View {
        Section("Extension memory") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(mb(memory.footprint)).font(.body.monospacedDigit())
                    Text("of \(mb(MemoryStats.limit))").foregroundStyle(.secondary)
                    Spacer()
                    Text("peak \(mb(memory.peakFootprint))").font(.caption.monospacedDigit())
                        .foregroundStyle(color(memory.peakFootprint))
                }
                ProgressView(value: Double(min(memory.footprint, MemoryStats.limit)),
                             total: Double(MemoryStats.limit))
                    .tint(color(memory.footprint))
            }
            LabeledContent("Go runtime") {
                Text("\(mb(UInt64(max(0, memory.goTotal)))) (heap \(mb(UInt64(max(0, memory.goHeap)))))")
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func color(_ bytes: UInt64) -> Color {
        let f = Double(bytes) / Double(MemoryStats.limit)
        return f < 0.6 ? .green : f < 0.8 ? .orange : .red
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
