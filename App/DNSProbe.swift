import Foundation
import Network

/// Sends a raw AAAA query over UDP straight to one resolver (through the tunnel),
/// bypassing the iOS resolver. Used to tell "resolver dead" from "split DNS not applied".
enum DNSProbe {
    enum Outcome: Equatable {
        case answer(address: String, ms: Int)
        case noAnswer(rcode: Int, ms: Int)   // server replied, but no AAAA (e.g. NXDOMAIN = 3)
        case timeout
        case failed(String)

        var summary: String {
            switch self {
            case .answer(let a, let ms): "\(a) · \(ms) ms"
            case .noAnswer(let rc, let ms): "replied rcode \(rc) · \(ms) ms"
            case .timeout: "no reply (timeout)"
            case .failed(let msg): msg
            }
        }

        var reachable: Bool {
            switch self {
            case .answer, .noAnswer: true
            default: false
            }
        }
    }

    static func query(server: String, name: String, timeout: TimeInterval = 4) async -> Outcome {
        guard let host = IPv6Address(server) else { return .failed("bad address") }
        let id = UInt16.random(in: 0...UInt16.max)
        let packet = buildQuery(id: id, name: name)
        let conn = NWConnection(host: .ipv6(host), port: 53, using: .udp)
        let start = Date()

        return await withCheckedContinuation { cont in
            let once = Once(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: packet, completion: .contentProcessed { err in
                        if let err { once.resume(.failed(err.localizedDescription)) }
                    })
                    conn.receiveMessage { data, _, _, err in
                        let ms = Int(Date().timeIntervalSince(start) * 1000)
                        if let data { once.resume(parse(data, id: id, ms: ms)) }
                        else { once.resume(.failed(err?.localizedDescription ?? "empty reply")) }
                    }
                case .failed(let err):
                    once.resume(.failed(err.localizedDescription))
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.timeout) }
            once.onResume = { conn.cancel() }
        }
    }

    // MARK: - Wire format

    static func buildQuery(id: UInt16, name: String) -> Data {
        var d = Data()
        d.append(UInt8(id >> 8)); d.append(UInt8(id & 0xFF))
        d.append(contentsOf: [0x01, 0x00,  // RD
                              0x00, 0x01,  // QDCOUNT
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            d.append(UInt8(bytes.count)); d.append(contentsOf: bytes)
        }
        d.append(0)
        d.append(contentsOf: [0x00, 0x1C, 0x00, 0x01]) // AAAA, IN
        return d
    }

    static func parse(_ data: Data, id: UInt16, ms: Int) -> Outcome {
        let b = [UInt8](data)
        guard b.count >= 12, UInt16(b[0]) << 8 | UInt16(b[1]) == id else { return .failed("malformed reply") }
        let rcode = Int(b[3] & 0x0F)
        let qd = Int(b[4]) << 8 | Int(b[5])
        let an = Int(b[6]) << 8 | Int(b[7])
        var i = 12

        func skipName() -> Bool {
            while i < b.count {
                let len = b[i]
                if len == 0 { i += 1; return true }
                if len & 0xC0 == 0xC0 { i += 2; return true }
                i += Int(len) + 1
            }
            return false
        }

        for _ in 0..<qd { guard skipName() else { return .failed("malformed reply") }; i += 4 }
        for _ in 0..<an {
            guard skipName(), i + 10 <= b.count else { break }
            let type = Int(b[i]) << 8 | Int(b[i + 1])
            let rdlen = Int(b[i + 8]) << 8 | Int(b[i + 9])
            i += 10
            guard i + rdlen <= b.count else { break }
            if type == 28, rdlen == 16, let addr = IPv6Address(Data(b[i..<i + 16])) {
                return .answer(address: "\(addr)", ms: ms)
            }
            i += rdlen
        }
        return .noAnswer(rcode: rcode, ms: ms)
    }
}

/// Resumes a continuation exactly once (reply vs. timeout race).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<DNSProbe.Outcome, Never>?
    var onResume: (() -> Void)?

    init(_ cont: CheckedContinuation<DNSProbe.Outcome, Never>) { self.cont = cont }

    func resume(_ value: DNSProbe.Outcome) {
        lock.lock()
        let c = cont
        cont = nil
        let cb = onResume
        lock.unlock()
        guard let c else { return }
        cb?()
        c.resume(returning: value)
    }
}
