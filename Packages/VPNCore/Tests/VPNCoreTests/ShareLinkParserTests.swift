import XCTest
@testable import VPNCore

final class ShareLinkParserTests: XCTestCase {
    func testVLESSRealityVision() throws {
        let server = try ShareLinkParser.parse(Fake.vlessReality)
        XCTAssertEqual(server.host, "nl.example.com")
        XCTAssertEqual(server.port, 443)
        XCTAssertEqual(server.name, "🇳🇱 Нидерланды")
        XCTAssertEqual(server.displayName, "Нидерланды")
        XCTAssertEqual(server.countryCode, "NL")
        XCTAssertEqual(server.summary, "VLESS · Reality")
        guard case .vless(let vless) = server.settings else { return XCTFail("not VLESS") }
        XCTAssertEqual(vless.uuid, Fake.uuid)
        XCTAssertEqual(vless.flow, "xtls-rprx-vision")
        XCTAssertEqual(vless.transport, .tcp)
        XCTAssertEqual(vless.security, .reality)
        XCTAssertEqual(vless.tls.serverName, "www.example.org")
        XCTAssertEqual(vless.tls.fingerprint, "chrome")
        XCTAssertEqual(vless.reality, RealityOptions(publicKey: Fake.realityKey, shortID: "0a1b", spiderX: "/"))
    }

    func testVLESSXHTTP() throws {
        let link = "vless://\(Fake.uuid)@de.example.com:8443?type=xhttp&security=reality&pbk=\(Fake.realityKey)"
            + "&sid=ab&sni=www.example.org&path=%2Fapi&host=cdn.example.net&mode=packet-up#DE%20XHTTP"
        let server = try ShareLinkParser.parse(link)
        XCTAssertEqual(server.summary, "VLESS · XHTTP · Reality")
        XCTAssertEqual(server.countryCode, "DE")
        guard case .vless(let vless) = server.settings else { return XCTFail("not VLESS") }
        XCTAssertEqual(vless.transport, .xhttp)
        XCTAssertEqual(vless.path, "/api")
        XCTAssertEqual(vless.host, "cdn.example.net")
        XCTAssertEqual(vless.xhttpMode, "packet-up")
    }

    func testVLESSWebSocketWithUnescapedName() throws {
        let link = "vless://\(Fake.uuid)@203.0.113.10:443?type=ws&security=tls&sni=ws.example.com"
            + "&path=%2Fws%3Fed%3D2048&host=ws.example.com&alpn=h2,http/1.1&fp=safari#Германия | WebSocket"
        let server = try ShareLinkParser.parse(link)
        XCTAssertEqual(server.name, "Германия | WebSocket")
        XCTAssertEqual(server.countryCode, "DE")
        XCTAssertEqual(server.summary, "VLESS · WS · TLS")
        guard case .vless(let vless) = server.settings else { return XCTFail("not VLESS") }
        XCTAssertEqual(vless.path, "/ws?ed=2048")
        XCTAssertEqual(vless.tls.alpn, ["h2", "http/1.1"])
    }

    func testVLESSGRPCServiceNameAndPathFallback() throws {
        let named = try ShareLinkParser.parse("vless://\(Fake.uuid)@g.example.com:443?type=grpc&security=tls&serviceName=svc#g")
        let fromPath = try ShareLinkParser.parse("vless://\(Fake.uuid)@g.example.com:443?type=grpc&security=tls&path=svc#g")
        for server in [named, fromPath] {
            guard case .vless(let vless) = server.settings else { return XCTFail("not VLESS") }
            XCTAssertEqual(vless.transport, .grpc)
            XCTAssertEqual(vless.serviceName, "svc")
            XCTAssertNil(vless.path)
        }
    }

    func testIPv6Host() throws {
        let server = try ShareLinkParser.parse("vless://\(Fake.uuid)@[2001:db8::1]:443?security=none#v6")
        XCTAssertEqual(server.host, "2001:db8::1")
        XCTAssertEqual(server.port, 443)
    }

    func testHysteria2() throws {
        let server = try ShareLinkParser.parse(Fake.hysteria2)
        XCTAssertEqual(server.host, "192.0.2.10")
        XCTAssertEqual(server.countryCode, "FI")
        XCTAssertEqual(server.summary, "Hysteria2")
        guard case .hysteria2(let hy2) = server.settings else { return XCTFail("not Hysteria2") }
        XCTAssertEqual(hy2.auth, "test-password")
        XCTAssertEqual(hy2.obfs, "salamander")
        XCTAssertEqual(hy2.obfsPassword, "test-obfs")
        XCTAssertEqual(hy2.tls.serverName, "hy.example.com")
        XCTAssertTrue(hy2.tls.allowInsecure)
    }

    func testHysteria2PortHoppingAndDefaultPort() throws {
        let hopping = try ShareLinkParser.parse("hy2://test-password@hy.example.com:443,20000-30000/?sni=hy.example.com#Hop")
        XCTAssertEqual(hopping.port, 443)
        guard case .hysteria2(let hy2) = hopping.settings else { return XCTFail("not Hysteria2") }
        XCTAssertEqual(hy2.portHopping, "443,20000-30000")

        let noPort = try ShareLinkParser.parse("hy2://test-password@hy.example.com?sni=hy.example.com")
        XCTAssertEqual(noPort.port, 443)
        XCTAssertEqual(noPort.name, "Hysteria2 hy.example.com")
    }

    func testErrors() {
        XCTAssertThrowsError(try ShareLinkParser.parse("trojan://test-password@t.example.com:443#t")) {
            XCTAssertEqual($0 as? ImportError, .unsupportedScheme("trojan"))
        }
        XCTAssertThrowsError(try ShareLinkParser.parse("vless://\(Fake.uuid)@nl.example.com?security=none")) {
            XCTAssertEqual($0 as? ImportError, .malformedLink("неверный порт"))
        }
        XCTAssertThrowsError(try ShareLinkParser.parse("vless://\(Fake.uuid)@nl.example.com:443?security=reality")) {
            XCTAssertEqual($0 as? ImportError, .missingField("pbk (ключ Reality)"))
        }
        XCTAssertThrowsError(try ShareLinkParser.parse("vless://\(Fake.uuid)@nl.example.com:443?type=kcp")) {
            XCTAssertEqual($0 as? ImportError, .unsupportedTransport("kcp"))
        }
        // The part after "vless://" without a user: tested on split() directly.
        XCTAssertThrowsError(try ShareLinkParser.split("nl.example.com:443")) {
            XCTAssertEqual($0 as? ImportError, .missingField("пользователь"))
        }
        XCTAssertThrowsError(try ShareLinkParser.parse("just text"))
    }

    func testIDIgnoresNameButNotSettings() throws {
        let a = try ShareLinkParser.parse("vless://\(Fake.uuid)@nl.example.com:443?security=none#One")
        let b = try ShareLinkParser.parse("vless://\(Fake.uuid)@nl.example.com:443?security=none#Two")
        let c = try ShareLinkParser.parse("vless://\(Fake.uuid)@nl.example.com:8443?security=none#One")
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, c.id)
    }
}
