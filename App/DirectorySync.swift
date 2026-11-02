import Foundation

/// Builds the ALFIS name table from the Yggdrasil Web directory HTML.
enum DirectorySync {
    struct Result: Equatable {
        var hosts: [String: String]
        var rows: Int
    }

    enum SyncError: LocalizedError {
        case http(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .http(let code): "Directory returned HTTP \(code)"
            case .empty: "No ALFIS names found in the directory"
            }
        }
    }

    static func fetch(from url: URL = AlfisDNS.directoryURL) async throws -> Result {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SyncError.http(http.statusCode)
        }
        let result = parse(String(decoding: data, as: UTF8.self))
        guard !result.hosts.isEmpty else { throw SyncError.empty }
        return result
    }

    // MARK: - Parsing (pure, unit-testable)

    private static let zonePattern = AlfisDNS.zones.joined(separator: "|")
    private static let domainRegex = try! NSRegularExpression(
        pattern: "^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+(?:\(zonePattern))$",
        options: [.caseInsensitive])
    private static let bracketedIPv6 = try! NSRegularExpression(pattern: "\\[([0-9a-fA-F:]{2,39})\\]")
    private static let tag = try! NSRegularExpression(pattern: "<[^>]*>")

    /// Each <tr> gives one address (first bracketed 200::/7 IPv6) and the names
    /// from a cell whose whole text is ALFIS domains. First row wins on duplicates.
    static func parse(_ html: String) -> Result {
        var hosts: [String: String] = [:]
        var rows = 0
        for row in html.components(separatedBy: "<tr").dropFirst() {
            let row = row.components(separatedBy: "</tr>").first ?? row
            guard let address = firstYggAddress(in: row) else { continue }
            rows += 1
            for cell in row.components(separatedBy: "<td").dropFirst() {
                let names = domains(inCell: cell)
                for name in names where hosts[name] == nil {
                    hosts[name] = address
                }
            }
        }
        return Result(hosts: hosts, rows: rows)
    }

    static func firstYggAddress(in s: String) -> String? {
        let range = NSRange(s.startIndex..., in: s)
        for m in bracketedIPv6.matches(in: s, range: range) {
            guard let r = Range(m.range(at: 1), in: s) else { continue }
            let candidate = String(s[r])
            var addr = in6_addr()
            guard inet_pton(AF_INET6, candidate, &addr) == 1,
                  addr.__u6_addr.__u6_addr8.0 & 0xFE == 0x02 else { continue }
            return candidate.lowercased()
        }
        return nil
    }

    /// Returns the cell's names only if *every* token is an ALFIS domain.
    static func domains(inCell cell: String) -> [String] {
        // Drop the rest of the opening <td ...> tag, then all tags and entities.
        guard let gt = cell.firstIndex(of: ">") else { return [] }
        let body = String(cell[cell.index(after: gt)...])
        var text = tag.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: " ")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        guard !tokens.isEmpty else { return [] }
        let all = tokens.allSatisfy { t in
            domainRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        }
        return all ? tokens : []
    }
}
