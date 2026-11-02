import XCTest
@testable import YggApp

final class DNSProbeTests: XCTestCase {
    func testQueryWireFormat() {
        let q = [UInt8](DNSProbe.buildQuery(id: 0xBEEF, name: "forum.ygg"))
        XCTAssertEqual(Array(q[0..<4]), [0xBE, 0xEF, 0x01, 0x00])        // ID, RD
        XCTAssertEqual(Array(q[4..<6]), [0x00, 0x01])                    // QDCOUNT
        XCTAssertEqual(Array(q[12...]), [5] + Array("forum".utf8) + [3] + Array("ygg".utf8)
                       + [0, 0x00, 0x1C, 0x00, 0x01])                    // QNAME, AAAA, IN
    }

    func testParsesAAAAAnswerWithCompressedName() {
        var reply = [UInt8](DNSProbe.buildQuery(id: 0xBEEF, name: "forum.ygg"))
        reply[2] = 0x81; reply[3] = 0x80; reply[7] = 1                   // QR|RD, RA, ANCOUNT=1
        reply += [0xC0, 0x0C, 0x00, 0x1C, 0x00, 0x01, 0, 0, 0, 60, 0x00, 0x10]
        reply += [0x02, 0x1a, 0x34, 0xaa, 0xc7, 0x82, 0x3a, 0xd2, 0x1b, 0xf8, 0x73, 0xf8, 0x01, 0x41, 0x66, 0xe8]

        XCTAssertEqual(DNSProbe.parse(Data(reply), id: 0xBEEF, ms: 7),
                       .answer(address: "21a:34aa:c782:3ad2:1bf8:73f8:141:66e8", ms: 7))
    }

    func testNXDomainAndMismatchedID() {
        var reply = [UInt8](DNSProbe.buildQuery(id: 1, name: "nope.ygg"))
        reply[2] = 0x81; reply[3] = 0x83                                  // RCODE 3
        XCTAssertEqual(DNSProbe.parse(Data(reply), id: 1, ms: 2), .noAnswer(rcode: 3, ms: 2))
        XCTAssertEqual(DNSProbe.parse(Data(reply), id: 2, ms: 2), .failed("malformed reply"))
        XCTAssertEqual(DNSProbe.parse(Data([0x00]), id: 1, ms: 2), .failed("malformed reply"))
    }
}
