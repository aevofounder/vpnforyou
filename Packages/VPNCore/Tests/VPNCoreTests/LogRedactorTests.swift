import XCTest
@testable import VPNCore

// Test data uses reserved values only: the all-zero UUID, example.com
// and documentation IP ranges (RFC 5737). Never put real keys here.
final class LogRedactorTests: XCTestCase {
    func testMasksVlessLink() {
        let line = "import vless://00000000-0000-0000-0000-000000000000@vpn.example.com:443?security=reality#NL done"
        XCTAssertEqual(LogRedactor.redact(line), "import vless://[скрыто] done")
    }

    func testMasksHysteria2Link() {
        XCTAssertEqual(
            LogRedactor.redact("hysteria2://test-password@192.0.2.10:443?sni=vpn.example.com"),
            "hysteria2://[скрыто]"
        )
    }

    func testMasksUUIDAndIPv4() {
        XCTAssertEqual(
            LogRedactor.redact("user 00000000-0000-0000-0000-000000000000 from 203.0.113.57"),
            "user [uuid] from [ip]"
        )
    }

    func testLeavesOrdinaryURLsAlone() {
        let line = "GET https://api.ipify.org"
        XCTAssertEqual(LogRedactor.redact(line), line)
    }

    func testMasksIPv6ButNotClockTimes() {
        XCTAssertEqual(LogRedactor.redact("dial [2001:db8::1]:443 at 21:49:03"), "dial [[ip6]]:443 at 21:49:03")
        XCTAssertEqual(LogRedactor.redact("from 2001:db8:0:0:0:0:0:1"), "from [ip6]")
        XCTAssertEqual(LogRedactor.redact("level=warning time=12:00:00"), "level=warning time=12:00:00")
    }

    func testMasksKnownServerHosts() {
        let line = "connect to nl.example.com:443 failed, retry vpn.nl.example.com"
        XCTAssertEqual(
            LogRedactor.redact(line, hosts: ["nl.example.com", "vpn.nl.example.com", "x"]),
            "connect to [сервер]:443 failed, retry [сервер]"
        )
    }
}
