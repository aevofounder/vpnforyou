import XCTest
@testable import VPNCore

private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let responses: [String: HTTPResponse]
    private let fallback: HTTPResponse
    private(set) var requestedAgents: [String] = []

    /// One answer for every User-Agent, or different answers per User-Agent.
    init(response: HTTPResponse, byAgent: [String: HTTPResponse] = [:]) {
        fallback = response
        responses = byAgent
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let agent = headers["User-Agent"] ?? ""
        requestedAgents.append(agent)
        return responses[agent] ?? fallback
    }
}

final class SubscriptionFetcherTests: XCTestCase {
    private let url = "https://sub.example.com/s/fake-token"

    func testFetchParsesBodyAndHeaders() async throws {
        let body = Fake.base64(Fake.vlessReality + "\n" + Fake.hysteria2)
        let client = StubHTTPClient(response: HTTPResponse(status: 200, headers: [
            "subscription-userinfo": "upload=1; download=2; total=100; expire=0",
            "profile-title": "base64:" + Fake.base64("Тестовый VPN"),
            "profile-update-interval": "6",
        ], body: Data(body.utf8)))

        let fetched = try await SubscriptionFetcher(client: client).fetch(url)
        XCTAssertEqual(fetched.parsed.servers.count, 2)
        XCTAssertEqual(fetched.usage?.total, 100)
        XCTAssertEqual(fetched.title, "Тестовый VPN")
        XCTAssertEqual(fetched.updateIntervalHours, 6)
        XCTAssertEqual(client.requestedAgents, [SubscriptionFetcher.jsonUserAgent])
    }

    func testAsksAsJSONClientFirst() async throws {
        let json = Fake.json([["remarks": "Германия | WebSocket", "outbounds": [[
            "tag": "proxy", "protocol": "vless",
            "settings": ["vnext": [["address": "de.example.com", "port": 443, "users": [["id": Fake.uuid]]]]],
            "streamSettings": ["network": "tcp", "security": "tls", "tlsSettings": ["serverName": "de.example.com"]],
        ]]]])
        let links = Data(Fake.base64(Fake.vlessReality).utf8)
        let client = StubHTTPClient(response: HTTPResponse(status: 200, headers: [:], body: links), byAgent: [
            SubscriptionFetcher.jsonUserAgent: HTTPResponse(status: 200, headers: [:], body: json),
        ])
        let fetched = try await SubscriptionFetcher(client: client).fetch(url)
        XCTAssertEqual(fetched.parsed.servers.map(\.name), ["Германия | WebSocket"])
        XCTAssertEqual(client.requestedAgents, [SubscriptionFetcher.jsonUserAgent])
    }

    func testFallsBackToLinksWhenJSONAnswerIsUnusable() async throws {
        let links = Data(Fake.base64(Fake.vlessReality).utf8)
        for unusable in [HTTPResponse(status: 403, headers: [:], body: Data()),
                         HTTPResponse(status: 200, headers: [:], body: Data("happ://crypt/fake".utf8))] {
            let client = StubHTTPClient(response: HTTPResponse(status: 200, headers: [:], body: links), byAgent: [
                SubscriptionFetcher.jsonUserAgent: unusable,
            ])
            let fetched = try await SubscriptionFetcher(client: client).fetch(url)
            XCTAssertEqual(fetched.parsed.servers.count, 1)
            XCTAssertEqual(client.requestedAgents, SubscriptionFetcher.defaultUserAgents)
        }
    }

    func testFetchErrors() async {
        let forbidden = StubHTTPClient(response: HTTPResponse(status: 403, headers: [:], body: Data()))
        await assertThrows(.httpStatus(403)) { _ = try await SubscriptionFetcher(client: forbidden).fetch(self.url) }
        await assertThrows(.invalidSubscriptionURL) { _ = try await SubscriptionFetcher(client: forbidden).fetch("ftp://sub.example.com/x") }

        let onlyTrojan = StubHTTPClient(response: HTTPResponse(status: 200, headers: [:],
                                                               body: Data("trojan://test-password@t.example.com:443".utf8)))
        await assertThrows(.nothingImported("Протокол trojan пока не поддерживается")) {
            _ = try await SubscriptionFetcher(client: onlyTrojan).fetch(self.url)
        }
    }

    func testSubscriptionURLHelpers() {
        XCTAssertEqual(SubscriptionURL.displayHost(url), "sub.example.com")
        XCTAssertFalse(SubscriptionURL.isInsecure(url))
        XCTAssertTrue(SubscriptionURL.isInsecure("http://sub.example.com/s/fake-token"))
        XCTAssertNil(SubscriptionURL.validate("vless://whatever"))
    }

    private func assertThrows(_ expected: ImportError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("no error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ImportError, expected, file: file, line: line)
        }
    }
}
