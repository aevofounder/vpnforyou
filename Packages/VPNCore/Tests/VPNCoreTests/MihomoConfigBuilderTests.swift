import Foundation
import XCTest
@testable import VPNCore

final class MihomoConfigBuilderTests: XCTestCase {
    /// A well-formed fake SHA-256 pin with colons, as Hysteria links write it.
    static let pin = (0..<32).map { _ in "AB" }.joined(separator: ":")

    static func sampleServers() throws -> [ServerConfig] {
        let links = [
            Fake.vlessReality,
            "vless://\(Fake.uuid)@de.example.com:8443?type=xhttp&security=reality&pbk=\(Fake.realityKey)&sid=ab&sni=www.example.org&path=%2Fx&mode=auto#DE",
            "vless://\(Fake.uuid)@203.0.113.10:443?type=ws&security=tls&sni=ws.example.com&path=%2Fws&host=ws.example.com&alpn=h2,http/1.1#WS",
            "vless://\(Fake.uuid)@g.example.com:443?type=grpc&security=tls&serviceName=svc#gRPC",
            "vless://\(Fake.uuid)@u.example.com:80?type=httpupgrade&security=none&path=%2Fup&host=u.example.com#Upgrade",
            Fake.hysteria2,
            "hy2://test-password@hy.example.com:443,20000-30000/?sni=hy.example.com&pinSHA256=" + Self.pin + "#Hop",
            "hy2://test-password@hy2.example.com:443/?sni=hy.example.com&pinSHA256=AB:CD:EF#BadPin",
        ]
        return try links.map(ShareLinkParser.parse)
    }

    static func sampleRequest(routing: RoutingMode, selectGroup: Bool = false) throws -> CoreStartRequest {
        let servers = try sampleServers()
        let group = ServerGroup(name: "Автовыбор", memberIDs: [servers[0].id, servers[1].id])
        let session = CoreSession(mixedPort: 29_091, mixedUser: "vfytest", mixedPassword: String(repeating: "b2", count: 16))
        return CoreStartRequest(
            servers: servers, groups: [group],
            selectedID: selectGroup ? group.id : servers[1].id,
            routing: routing,
            appPaths: ["/Applications/Telegram.app", "/Applications/Google Chrome.app", "/Users/test/Applications/A, B (2) 'q'.app"],
            session: session
        )
    }

    func testVLESSAndHysteria2Proxies() throws {
        let proxies = try Self.sampleServers().map(MihomoConfigBuilder.proxy)

        let reality = proxies[0]
        XCTAssertEqual(reality["type"] as? String, "vless")
        XCTAssertEqual(reality["uuid"] as? String, Fake.uuid)
        XCTAssertEqual(reality["flow"] as? String, "xtls-rprx-vision")
        XCTAssertEqual(reality["network"] as? String, "tcp")
        XCTAssertEqual(reality["tls"] as? Bool, true)
        XCTAssertEqual(reality["servername"] as? String, "www.example.org")
        XCTAssertEqual((reality["reality-opts"] as? [String: Any])?["public-key"] as? String, Fake.realityKey)
        XCTAssertNil(reality["encryption"], "encryption=none must not be passed on")

        let xhttp = proxies[1]
        XCTAssertEqual(xhttp["network"] as? String, "xhttp")
        XCTAssertEqual((xhttp["xhttp-opts"] as? [String: Any])?["mode"] as? String, "auto")

        let ws = proxies[2]
        XCTAssertEqual((ws["ws-opts"] as? [String: Any])?["path"] as? String, "/ws")
        XCTAssertEqual(ws["alpn"] as? [String], ["h2", "http/1.1"])

        XCTAssertEqual((proxies[3]["grpc-opts"] as? [String: Any])?["grpc-service-name"] as? String, "svc")

        let upgrade = proxies[4]
        XCTAssertNil(upgrade["tls"])
        XCTAssertEqual((upgrade["ws-opts"] as? [String: Any])?["v2ray-http-upgrade"] as? Bool, true)

        let hy2 = proxies[5]
        XCTAssertEqual(hy2["type"] as? String, "hysteria2")
        XCTAssertEqual(hy2["password"] as? String, "test-password")
        XCTAssertEqual(hy2["obfs"] as? String, "salamander")
        XCTAssertEqual(hy2["skip-cert-verify"] as? Bool, true)
        XCTAssertEqual(proxies[6]["ports"] as? String, "443,20000-30000")
        XCTAssertEqual(proxies[6]["fingerprint"] as? String, String(repeating: "ab", count: 32))
        XCTAssertNil(proxies[7]["fingerprint"], "a malformed pin is dropped, not passed to mihomo")
    }

    func testRulesPerMode() throws {
        let all = MihomoConfigBuilder.rules(for: try Self.sampleRequest(routing: .all))
        XCTAssertEqual(all.first, "IN-PORT,29091,PROXY")
        XCTAssertEqual(all[1], "PROCESS-NAME,VPNforYou,DIRECT")
        XCTAssertEqual(all.last, "MATCH,PROXY")
        XCTAssertFalse(all.contains { $0.hasPrefix("RULE-SET") })

        let only = MihomoConfigBuilder.rules(for: try Self.sampleRequest(routing: .onlySelected))
        XCTAssertEqual(Array(only.suffix(2)), ["RULE-SET,apps,PROXY", "MATCH,DIRECT"])

        let except = MihomoConfigBuilder.rules(for: try Self.sampleRequest(routing: .allExceptSelected))
        XCTAssertEqual(Array(except.suffix(2)), ["RULE-SET,apps,DIRECT", "MATCH,PROXY"])
    }

    func testSelectorPutsChoiceFirstAndGroupsAreURLTest() throws {
        let request = try Self.sampleRequest(routing: .all, selectGroup: true)
        let groups = MihomoConfigBuilder.proxyGroups(for: request)
        let selector = try XCTUnwrap(groups.last)
        XCTAssertEqual(selector["name"] as? String, "PROXY")
        XCTAssertEqual((selector["proxies"] as? [String])?.first, request.groups[0].id)
        XCTAssertEqual((selector["proxies"] as? [String])?.count, 1 + request.servers.count)
        XCTAssertEqual(groups.first?["type"] as? String, "url-test")
    }

    func testConfigListensOnLoopbackOnly() throws {
        let config = try MihomoConfigBuilder.config(for: try Self.sampleRequest(routing: .onlySelected),
                                                    appsRulesPath: "/tmp/apps.yaml", apiSocketPath: "/tmp/api.sock")
        XCTAssertEqual(config["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual(config["allow-lan"] as? Bool, false)
        XCTAssertNotNil(config["rule-providers"])
        let data = try MihomoConfigBuilder.configData(for: try Self.sampleRequest(routing: .all),
                                                      appsRulesPath: "/tmp/apps.yaml", apiSocketPath: "/tmp/api.sock")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\\/"), "YAML rejects \\/")
    }

    /// The core's API must not be reachable over TCP: a process that could talk to it
    /// could load any config into the root core (`PUT /configs`) or replace it (`/upgrade`).
    func testAPIOnlyOnUnixSocket() throws {
        for routing in RoutingMode.allCases {
            let config = try MihomoConfigBuilder.config(for: try Self.sampleRequest(routing: routing),
                                                        appsRulesPath: "/tmp/apps.yaml", apiSocketPath: "/tmp/api.sock")
            XCTAssertEqual(config["external-controller-unix"] as? String, "/tmp/api.sock")
            for key in ["external-controller", "external-controller-tls", "external-controller-pipe", "secret",
                        "external-ui", "external-ui-url", "external-doh-server"] {
                XCTAssertNil(config[key], key)
            }
        }
    }

    func testValidationRejectsBadInput() throws {
        var request = try Self.sampleRequest(routing: .all)
        request.selectedID = "s-missing"
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(request)) { XCTAssertEqual($0 as? CoreConfigError, .unknownSelection) }

        request = try Self.sampleRequest(routing: .all)
        request.session.mixedPort = 80
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(request)) { XCTAssertEqual($0 as? CoreConfigError, .invalidPort(80)) }

        request = try Self.sampleRequest(routing: .all)
        request.session.mixedPassword = "short"
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(request)) { XCTAssertEqual($0 as? CoreConfigError, .invalidSecret) }

        request = try Self.sampleRequest(routing: .onlySelected)
        request.appPaths = ["/Applications/Evil.app\n- MATCH,DIRECT"]
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(request)) { XCTAssertEqual($0 as? CoreConfigError, .invalidAppPath) }

        request = try Self.sampleRequest(routing: .onlySelected)
        request.appPaths = ["relative/path.app"]
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(request)) { XCTAssertEqual($0 as? CoreConfigError, .invalidAppPath) }

        request = try Self.sampleRequest(routing: .all)
        request.servers = []
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(request)) { XCTAssertEqual($0 as? CoreConfigError, .noServers) }

        request = try Self.sampleRequest(routing: .all)
        if case .hysteria2(var hy2) = request.servers[6].settings {
            hy2.portHopping = "443;rm -rf"
            request.servers[6].settings = .hysteria2(hy2)
        }
        XCTAssertThrowsError(try MihomoConfigBuilder.validate(request)) { XCTAssertEqual($0 as? CoreConfigError, .invalidValue("ports")) }
    }

    func testAppsRulesEscaping() {
        let text = MihomoConfigBuilder.appsRules(paths: ["/Applications/Google Chrome.app", "/Apps/A, B (2) 'q'.app"])
        XCTAssertEqual(text, """
        payload:
          - 'PROCESS-PATH-REGEX,^/Applications/Google Chrome\\.app/'
          - 'PROCESS-PATH-REGEX,^/Apps/A\\x2C B \\(2\\) \\x27q\\x27\\.app/'

        """)
        XCTAssertTrue(MihomoConfigBuilder.appsRules(paths: []).contains("PROCESS-NAME,vpnforyou-no-apps-selected"))
    }

    func testRandomSessionIsValid() throws {
        let session = CoreSession.random(mixedPort: 30_001)
        var request = try Self.sampleRequest(routing: .all)
        request.session = session
        XCTAssertNoThrow(try MihomoConfigBuilder.validate(request))
        XCTAssertEqual(session.mixedPassword.count, 48)
        XCTAssertNotEqual(session.mixedPassword, CoreSession.random(mixedPort: 30_001).mixedPassword)
    }

    /// Writes sample configs for `mihomo -t` when MIHOMO_CHECK_DIR is set (CI and local checks).
    func testWriteSampleConfigsForMihomo() throws {
        guard let directory = ProcessInfo.processInfo.environment["MIHOMO_CHECK_DIR"] else {
            throw XCTSkip("MIHOMO_CHECK_DIR is not set")
        }
        let base = URL(fileURLWithPath: directory)
        for (name, routing, group) in [("all", RoutingMode.all, false), ("only", .onlySelected, true), ("except", .allExceptSelected, false)] {
            let folder = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let request = try Self.sampleRequest(routing: routing, selectGroup: group)
            let appsPath = folder.appendingPathComponent(MihomoConfigBuilder.appsFileName).path
            try MihomoConfigBuilder.configData(for: request, appsRulesPath: appsPath,
                                               apiSocketPath: folder.appendingPathComponent("api.sock").path)
                .write(to: folder.appendingPathComponent("config.json"))
            try Data(MihomoConfigBuilder.appsRules(paths: request.appPaths).utf8)
                .write(to: URL(fileURLWithPath: appsPath))
        }
    }
}
