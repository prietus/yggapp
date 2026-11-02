import XCTest
@testable import YggApp

final class DirectorySyncTests: XCTestCase {
    func testParsesNamesFromDirectoryFixture() throws {
        let result = DirectorySync.parse(try fixture("directory", "html"))

        XCTAssertEqual(result.hosts, [
            "acetone.ygg": "324:71e:281a:9ed3::ace",
            "forum.ygg": "21a:34aa:c782:3ad2:1bf8:73f8:141:66e8",
            "map.mc.ygg": "201:92e3:d9df:4932:ca24:586a:4475:6e8b",
            "fb.ygg": "316:a486:ec13:8e37:be24:11ff:fe1c:bea3",
            "searx.odmincheg.ygg": "300:ffb4:8643:34d8::f1fa:0",
            "speedtest.odmincheg.ygg": "300:ffb4:8643:34d8::f1fa:1",
            "a.ygg": "203:75b7:45af:ecca:d641:cd42:38dc:4788",
            "b.anon": "203:75b7:45af:ecca:d641:cd42:38dc:4788",
        ])
        // Every row with a 200::/7 address counts, with or without a name.
        XCTAssertEqual(result.rows, 10)
    }

    func testDomainMentionedInDescriptionIsIgnored() {
        // "mc.ygg" appears only inside a description sentence.
        XCTAssertEqual(DirectorySync.domains(inCell: #">Minecraft server map "mc.ygg"</td>"#), [])
        XCTAssertEqual(DirectorySync.domains(inCell: ">map.mc.ygg</td>"), ["map.mc.ygg"])
    }

    func testCellWithMixedTokensIsRejected() {
        XCTAssertEqual(DirectorySync.domains(inCell: ">forum.ygg and more</td>"), [])
        XCTAssertEqual(DirectorySync.domains(inCell: ">example.org</td>"), [])
    }

    func testOnlyYggdrasilAddressesAreAccepted() {
        XCTAssertNil(DirectorySync.firstYggAddress(in: "http://[2001:db8::1]/"))
        XCTAssertNil(DirectorySync.firstYggAddress(in: "http://[fe80::1]/"))
        XCTAssertEqual(DirectorySync.firstYggAddress(in: "x [2001:db8::1] y [3FF:1::2]"), "3ff:1::2")
    }
}

func fixture(_ name: String, _ ext: String) throws -> String {
    let url = try XCTUnwrap(Bundle(for: DirectorySyncTests.self).url(forResource: name, withExtension: ext),
                            "missing fixture \(name).\(ext)")
    return try String(contentsOf: url, encoding: .utf8)
}
