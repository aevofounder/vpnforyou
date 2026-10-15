import XCTest
@testable import VPNCore

final class XrayJSONParserTests: XCTestCase {
    private func vlessOutbound(host: String, tag: String, network: String = "tcp", extra: [String: Any] = [:]) -> [String: Any] {
        var stream: [String: Any] = [
            "network": network,
            "security": "reality",
            "realitySettings": [
                "serverName": "www.example.org",
                "fingerprint": "chrome",
                "publicKey": Fake.realityKey,
                "shortId": "0a1b",
            ],
        ]
        stream.merge(extra) { _, new in new }
        return [
            "tag": tag,
            "protocol": "vless",
            "settings": ["vnext": [["address": host, "port": 443, "users": [["id": Fake.uuid, "encryption": "none"]]]]],
            "streamSettings": stream,
        ]
    }

    private let direct: [String: Any] = ["tag": "direct", "protocol": "freedom"]
    private let block: [String: Any] = ["tag": "block", "protocol": "blackhole"]

    func testSingleVLESSXHTTPConfig() throws {
        let outbound = vlessOutbound(host: "de.example.com", tag: "proxy", network: "xhttp", extra: [
            "xhttpSettings": ["path": "/x", "host": "cdn.example.net", "mode": "auto"],
        ])
        let data = Fake.json([["remarks": "🇩🇪 Германия | XHTTP", "outbounds": [outbound, direct, block]]])
        let parsed = try XrayJSONParser.parse(data)

        XCTAssertEqual(parsed.servers.count, 1)
        XCTAssertTrue(parsed.groups.isEmpty)
        let server = parsed.servers[0]
        XCTAssertEqual(server.name, "🇩🇪 Германия | XHTTP")
        XCTAssertEqual(server.countryCode, "DE")
        XCTAssertEqual(server.summary, "VLESS · XHTTP · Reality")
        guard case .vless(let vless) = server.settings else { return XCTFail("not VLESS") }
        XCTAssertEqual(vless.uuid, Fake.uuid)
        XCTAssertEqual(vless.path, "/x")
        XCTAssertEqual(vless.host, "cdn.example.net")
        XCTAssertEqual(vless.xhttpMode, "auto")
        XCTAssertEqual(vless.reality?.publicKey, Fake.realityKey)
        XCTAssertEqual(vless.tls.serverName, "www.example.org")
    }

    func testFlatVLESSSettingsAndSingleObject() throws {
        let outbound: [String: Any] = [
            "protocol": "vless",
            "settings": ["address": "203.0.113.5", "port": "8443", "id": Fake.uuid, "flow": "xtls-rprx-vision"],
            "streamSettings": ["network": "ws", "security": "tls",
                               "tlsSettings": ["serverName": "ws.example.com", "alpn": ["h2"]],
                               "wsSettings": ["path": "/ws", "headers": ["Host": "ws.example.com"]]],
        ]
        let parsed = try XrayJSONParser.parse(Fake.json(["remarks": "Польша", "outbounds": [outbound]]))
        let server = try XCTUnwrap(parsed.servers.first)
        XCTAssertEqual(server.port, 8443)
        XCTAssertEqual(server.countryCode, "PL")
        guard case .vless(let vless) = server.settings else { return XCTFail("not VLESS") }
        XCTAssertEqual(vless.flow, "xtls-rprx-vision")
        XCTAssertEqual(vless.host, "ws.example.com")
        XCTAssertEqual(vless.tls.alpn, ["h2"])
    }

    func testHysteria2WithSalamander() throws {
        let outbound: [String: Any] = [
            "protocol": "hysteria",
            "settings": ["version": 2, "address": "192.0.2.20", "port": 443],
            "streamSettings": [
                "network": "hysteria",
                "security": "tls",
                "tlsSettings": ["serverName": "hy.example.com", "alpn": ["h3"]],
                "hysteriaSettings": ["version": 2, "auth": "test-password"],
                "finalmask": ["udp": [["type": "salamander", "settings": ["password": "test-obfs"]]]],
            ],
        ]
        let parsed = try XrayJSONParser.parse(Fake.json([["remarks": "Германия | Hysteria2", "outbounds": [outbound]]]))
        let server = try XCTUnwrap(parsed.servers.first)
        XCTAssertEqual(server.summary, "Hysteria2")
        guard case .hysteria2(let hy2) = server.settings else { return XCTFail("not Hysteria2") }
        XCTAssertEqual(hy2.auth, "test-password")
        XCTAssertEqual(hy2.obfs, "salamander")
        XCTAssertEqual(hy2.obfsPassword, "test-obfs")
        XCTAssertEqual(hy2.tls.alpn, ["h3"])
    }

    func testBalancerBecomesGroupAndSharesStandaloneServer() throws {
        let a = vlessOutbound(host: "a.example.com", tag: "proxy-1")
        let b = vlessOutbound(host: "b.example.com", tag: "proxy-2")
        let auto: [String: Any] = [
            "remarks": "Автовыбор",
            "outbounds": [a, b, direct],
            "routing": ["balancers": [["tag": "auto", "selector": ["proxy-"]]]],
        ]
        let standaloneB: [String: Any] = ["remarks": "Германия | WebSocket", "outbounds": [b]]
        let parsed = try XrayJSONParser.parse(Fake.json([auto, standaloneB]))

        XCTAssertEqual(parsed.servers.count, 2)
        XCTAssertEqual(parsed.groups.count, 1)
        let group = parsed.groups[0]
        XCTAssertEqual(group.name, "Автовыбор")
        XCTAssertEqual(group.memberIDs.count, 2)

        let visible = parsed.servers.filter { $0.isHidden != true }
        XCTAssertEqual(visible.map(\.name), ["Германия | WebSocket"])
        let hidden = parsed.servers.filter { $0.isHidden == true }
        XCTAssertEqual(hidden.map(\.name), ["Автовыбор · proxy-1"])
    }

    func testUnsupportedProtocolIsSkipped() throws {
        let trojan: [String: Any] = ["protocol": "trojan", "settings": ["servers": [["address": "t.example.com", "port": 443]]]]
        let parsed = try XrayJSONParser.parse(Fake.json([["remarks": "Trojan", "outbounds": [trojan, direct]]]))
        XCTAssertTrue(parsed.servers.isEmpty)
        XCTAssertEqual(parsed.skipped, [SkippedEntry(name: "Trojan", reason: "Протокол trojan пока не поддерживается")])
    }

    func testBrokenOutboundIsSkippedWithReason() throws {
        var outbound = vlessOutbound(host: "nl.example.com", tag: "proxy")
        outbound["streamSettings"] = ["network": "tcp", "security": "reality", "realitySettings": [:]]
        let parsed = try XrayJSONParser.parse(Fake.json([["remarks": "Сломанный", "outbounds": [outbound]]]))
        XCTAssertTrue(parsed.servers.isEmpty)
        XCTAssertEqual(parsed.skipped.first?.reason, ImportError.missingField("publicKey (ключ Reality)").message)
    }
}
