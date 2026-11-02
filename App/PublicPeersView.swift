import SwiftUI

/// Browse public peers by country, measure latency from this device, tap to add.
struct PublicPeersView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var all: [PublicPeer] = []
    @State private var country: String?
    @State private var measured: [String: Int?] = [:]   // uri -> ms (nil = unreachable)
    @State private var loading = false
    @State private var measuring = false
    @State private var error: String?

    private static let anywhere = "All countries"

    private var countries: [String] {
        [Self.anywhere] + Array(Set(all.filter(\.up).map(\.country))).sorted()
    }

    private var peers: [PublicPeer] {
        all.filter { $0.up && (country == Self.anywhere || $0.country == country) }
            .sorted { rank($0) < rank($1) }
    }

    /// Our own measurement wins; unreachable sinks to the bottom; then the monitor's value.
    private func rank(_ p: PublicPeer) -> Int {
        if let m = measured[p.uri] { return m ?? Int.max - 1 }
        return 100_000 + (p.responseMs ?? 50_000)
    }

    var body: some View {
        NavigationStack {
            List {
                if !countries.isEmpty {
                    Picker("Country", selection: $country) {
                        ForEach(countries, id: \.self) { c in
                            let n = c == Self.anywhere ? all.filter(\.up).count
                                                       : all.filter { $0.up && $0.country == c }.count
                            Text("\(c) (\(n))").tag(Optional(c))
                        }
                    }
                    .onChange(of: country) { _ in Task { await measureAll() } }
                }

                Section {
                    ForEach(peers) { peer in
                        Button { Task { await tunnel.addPeer(peer.uri) } } label: { row(peer) }
                            .disabled(tunnel.peers.contains(peer.uri))
                    }
                } header: {
                    if !peers.isEmpty {
                        HStack {
                            Text("\(peers.count) online")
                            Spacer()
                            if measuring { ProgressView().controlSize(.mini) }
                        }
                    }
                } footer: {
                    Text("Latency is measured from this device with a TCP connect; QUIC peers show the list's own check. Two or three nearby peers are plenty.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Public peers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add fastest") { Task { await addFastest() } }
                        .disabled(measuring || peers.isEmpty)
                }
            }
            .refreshable { await load() }
            .task { if all.isEmpty { await load() } }
        }
    }

    private func row(_ peer: PublicPeer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.host ?? peer.uri).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(peer.scheme.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    Text(":\(peer.port.map(String.init) ?? "?")").font(.caption.monospaced())
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if tunnel.peers.contains(peer.uri) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                latency(peer)
            }
        }
    }

    @ViewBuilder private func latency(_ peer: PublicPeer) -> some View {
        if let m = measured[peer.uri] {
            if let ms = m {
                Text("\(ms) ms").font(.callout.monospacedDigit())
                    .foregroundStyle(ms < 80 ? .green : ms < 200 ? .orange : .red)
            } else {
                Text("unreachable").font(.caption).foregroundStyle(.red)
            }
        } else if let ms = peer.responseMs {
            Text("~\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            all = try await PublicPeers.fetch()
            error = nil
            if country == nil || !countries.contains(country!) {
                // Prefer the device's country only if it has a real choice of peers.
                let mine = PublicPeers.deviceCountry ?? ""
                let mineCount = all.filter { $0.up && $0.country == mine }.count
                country = mineCount >= 3 ? mine : Self.anywhere
            }
            await measureAll()
        } catch {
            self.error = "Couldn't load the peer list: \(error.localizedDescription)"
        }
    }

    /// Measures unmeasured TCP peers in view, at most `width` connects at a time.
    private func measureAll(width: Int = 24) async {
        var queue = peers.filter { $0.isTCP && measured[$0.uri] == nil }[...]
        guard !queue.isEmpty else { return }
        measuring = true
        defer { measuring = false }
        await withTaskGroup(of: (String, Int?).self) { group in
            func next() {
                guard let p = queue.popFirst() else { return }
                group.addTask { (p.uri, await PublicPeers.measure(p)) }
            }
            for _ in 0..<width { next() }
            for await (uri, ms) in group {
                measured[uri] = .some(ms)
                next()
            }
        }
    }

    /// Adds the two fastest reachable peers not already configured.
    private func addFastest() async {
        let candidates = peers.filter { !tunnel.peers.contains($0.uri) && (measured[$0.uri] ?? 0) != nil }
        for p in candidates.prefix(2) { await tunnel.addPeer(p.uri) }
    }
}
