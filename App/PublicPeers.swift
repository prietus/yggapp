import Foundation
import Network

/// Public peer list from publicpeers.neilalexander.dev (built from the
/// yggdrasil-network/public-peers repo and health-checked by its monitor).
struct PublicPeer: Identifiable, Equatable {
    var id: String { uri }
    let uri: String
    let country: String
    let up: Bool
    let responseMs: Int?     // measured by the list's monitor, not from this device
    let lastSeen: Date?

    var scheme: String { URL(string: uri)?.scheme ?? "?" }
    var host: String? { URL(string: uri)?.host }
    var port: Int? { URL(string: uri)?.port }

    /// TCP-based transports we can time with a plain TCP connect.
    var isTCP: Bool { ["tcp", "tls", "ws", "wss"].contains(scheme) }
}

enum PublicPeers {
    static let listURL = URL(string: "https://publicpeers.neilalexander.dev/publicnodes.json")!

    private struct Entry: Decodable {
        let up: Bool?
        let response_ms: Int?
        let last_seen: TimeInterval?
    }

    static func fetch() async throws -> [PublicPeer] {
        var request = URLRequest(url: listURL, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [PublicPeer] {
        let raw = try JSONDecoder().decode([String: [String: Entry]].self, from: data)
        return raw.flatMap { file, peers in
            peers.map { uri, e in
                PublicPeer(uri: uri,
                           country: countryName(fromFile: file),
                           up: e.up ?? false,
                           responseMs: e.response_ms,
                           lastSeen: e.last_seen.map { Date(timeIntervalSince1970: $0) })
            }
        }
    }

    /// "united-kingdom.md" -> "United Kingdom"
    static func countryName(fromFile file: String) -> String {
        file.replacingOccurrences(of: ".md", with: "")
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The device's region in English ("Spain"), to preselect a country.
    static var deviceCountry: String? {
        guard let code = Locale.current.region?.identifier else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code)
    }

    /// Time to open a TCP connection to the peer from this device, in ms.
    static func measure(_ peer: PublicPeer, timeout: TimeInterval = 3) async -> Int? {
        guard peer.isTCP, let host = peer.host, let port = peer.port,
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = Date()
        return await withCheckedContinuation { cont in
            let once = ResumeOnce(cont) { conn.cancel() }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(Int(Date().timeIntervalSince(start) * 1000))
                case .failed, .cancelled, .waiting: once.resume(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }
}

/// Resumes a continuation exactly once (connect vs. timeout race), then cleans up.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    private let cleanup: () -> Void

    init(_ cont: CheckedContinuation<T, Never>, cleanup: @escaping () -> Void) {
        self.cont = cont
        self.cleanup = cleanup
    }

    func resume(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        guard let c else { return }
        cleanup()
        c.resume(returning: value)
    }
}
