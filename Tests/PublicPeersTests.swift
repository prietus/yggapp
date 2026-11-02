import XCTest
@testable import YggApp

final class PublicPeersTests: XCTestCase {
    func testParsesPeerList() throws {
        let peers = try PublicPeers.parse(Data(try fixture("publicnodes", "json").utf8))
        XCTAssertEqual(peers.count, 5)
        XCTAssertEqual(peers.filter(\.up).count, 4)
        XCTAssertEqual(Set(peers.map(\.country)), ["France", "United Kingdom", "Armenia"])

        let tls = try XCTUnwrap(peers.first { $0.uri == "tls://51.15.204.214:54321" })
        XCTAssertEqual(tls.responseMs, 30)
        XCTAssertEqual(tls.host, "51.15.204.214")
        XCTAssertEqual(tls.port, 54321)
        XCTAssertNotNil(tls.lastSeen)

        let down = try XCTUnwrap(peers.first { $0.country == "Armenia" })
        XCTAssertFalse(down.up)
        XCTAssertNil(down.responseMs)
        XCTAssertNil(down.lastSeen)
    }

    func testOnlyTCPTransportsAreMeasurable() throws {
        let peers = try PublicPeers.parse(Data(try fixture("publicnodes", "json").utf8))
        let byScheme = Dictionary(grouping: peers, by: \.scheme).mapValues { $0.allSatisfy(\.isTCP) }
        XCTAssertEqual(byScheme["tls"], true)
        XCTAssertEqual(byScheme["tcp"], true)
        XCTAssertEqual(byScheme["quic"], false)
    }

    func testKeyQueryDoesNotBreakHostParsing() throws {
        let peers = try PublicPeers.parse(Data(try fixture("publicnodes", "json").utf8))
        let uk = try XCTUnwrap(peers.first { $0.country == "United Kingdom" })
        XCTAssertEqual(uk.host, "uk.example.org")
        XCTAssertEqual(uk.port, 443)
    }

    func testCountryNames() {
        XCTAssertEqual(PublicPeers.countryName(fromFile: "united-kingdom.md"), "United Kingdom")
        XCTAssertEqual(PublicPeers.countryName(fromFile: "spain.md"), "Spain")
        XCTAssertEqual(PublicPeers.countryName(fromFile: "hong_kong.md"), "Hong Kong")
    }
}
