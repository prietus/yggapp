import XCTest
@testable import YggApp

@MainActor
final class BrowserAddressTests: XCTestCase {
    func testTypedInputBecomesURL() {
        let cases: [(String, String)] = [
            ("forum.ygg", "http://forum.ygg"),
            ("  forum.ygg/index.php?board=1 ", "http://forum.ygg/index.php?board=1"),
            ("21a:34aa:c782:3ad2:1bf8:73f8:141:66e8", "http://[21a:34aa:c782:3ad2:1bf8:73f8:141:66e8]/"),
            ("300:ffb4:8643:34d8::f1fa:0", "http://[300:ffb4:8643:34d8::f1fa:0]/"),
            ("[300:ffb4:8643:34d8::f1fa:0]/search?q=x", "http://[300:ffb4:8643:34d8::f1fa:0]/search?q=x"),
            ("https://example.org/", "https://example.org/"),
        ]
        for (input, want) in cases {
            XCTAssertEqual(BrowserModel.url(from: input)?.absoluteString, want, "input: \(input)")
        }
        XCTAssertNil(BrowserModel.url(from: "   "))
    }

    func testDisplayHidesSchemeAndRootSlash() {
        let cases: [(String, String)] = [
            ("http://forum.ygg/", "forum.ygg"),
            ("http://forum.ygg/index.php", "forum.ygg/index.php"),
            ("http://forum.ygg/?topic=1", "forum.ygg/?topic=1"),
            ("http://[300:ffb4:8643:34d8::f1fa:0]/", "[300:ffb4:8643:34d8::f1fa:0]"),
            ("https://example.org/", "https://example.org"),
        ]
        for (url, want) in cases {
            XCTAssertEqual(BrowserModel.display(URL(string: url)!), want, "url: \(url)")
        }
    }

    func testDisplayedAddressReopensSamePage() {
        for s in ["http://forum.ygg/index.php", "http://[300:ffb4:8643:34d8::f1fa:0]/search?q=x"] {
            let url = URL(string: s)!
            XCTAssertEqual(BrowserModel.url(from: BrowserModel.display(url)), url)
        }
    }
}
