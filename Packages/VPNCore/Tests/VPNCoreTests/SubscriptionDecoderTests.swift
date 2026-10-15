import XCTest
@testable import VPNCore

final class SubscriptionDecoderTests: XCTestCase {
    private var list: String {
        """
        # comment
        \(Fake.vlessReality)

        \(Fake.hysteria2)
        trojan://test-password@t.example.com:443#Trojan
        vless://broken
        """
    }

    func testPlainList() throws {
        let parsed = try SubscriptionDecoder.decode(text: list)
        XCTAssertEqual(parsed.servers.count, 2)
        XCTAssertEqual(parsed.skipped.map(\.name), ["trojan", "vless"])
    }

    func testBase64Variants() throws {
        let standard = try SubscriptionDecoder.decode(Data(Fake.base64(list).utf8))
        let urlSafe = try SubscriptionDecoder.decode(text: Fake.urlSafeBase64NoPadding(list))
        XCTAssertEqual(standard.servers.count, 2)
        XCTAssertEqual(urlSafe.servers.map(\.id), standard.servers.map(\.id))
    }

    func testDuplicateLinksAreMerged() throws {
        let parsed = try SubscriptionDecoder.decode(text: Fake.vlessReality + "\n" + Fake.vlessReality)
        XCTAssertEqual(parsed.servers.count, 1)
    }

    func testXrayJSONText() throws {
        let outbound: [String: Any] = [
            "protocol": "vless",
            "settings": ["vnext": [["address": "nl.example.com", "port": 443, "users": [["id": Fake.uuid]]]]],
        ]
        let text = String(decoding: Fake.json([["remarks": "Нидерланды", "outbounds": [outbound]]]), as: UTF8.self)
        let parsed = try SubscriptionDecoder.decode(text: text)
        XCTAssertEqual(parsed.servers.first?.countryCode, "NL")
    }

    func testUnsupportedAndBrokenInput() {
        XCTAssertThrowsError(try SubscriptionDecoder.decode(text: "proxies:\n  - name: test")) {
            XCTAssertEqual($0 as? ImportError, .unsupportedFormat("Clash YAML"))
        }
        XCTAssertThrowsError(try SubscriptionDecoder.decode(text: "!!!")) {
            XCTAssertEqual($0 as? ImportError, .unrecognizedFormat)
        }
        XCTAssertThrowsError(try SubscriptionDecoder.decode(text: "  \n ")) {
            XCTAssertEqual($0 as? ImportError, .emptySubscription)
        }
    }
}
