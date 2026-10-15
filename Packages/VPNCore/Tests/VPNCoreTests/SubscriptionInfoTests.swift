import XCTest
@testable import VPNCore

final class SubscriptionInfoTests: XCTestCase {
    func testUsageHeader() throws {
        let gib: Int64 = 1_073_741_824
        let usage = try XCTUnwrap(SubscriptionUsage(header: "upload=\(gib); download=\(2 * gib); total=\(10 * gib); expire=1893456000"))
        XCTAssertEqual(usage.used, 3 * gib)
        XCTAssertEqual(try XCTUnwrap(usage.fractionUsed), 0.3, accuracy: 0.0001)
        XCTAssertEqual(usage.expiresAt, Date(timeIntervalSince1970: 1_893_456_000))

        let now = Date(timeIntervalSince1970: 1_893_456_000 - 86_400 * 24 + 60)
        XCTAssertEqual(usage.daysLeft(now: now), 24)
        XCTAssertEqual(usage.daysLeft(now: Date(timeIntervalSince1970: 1_893_456_001)), 0)
    }

    func testUnlimitedAndGarbage() throws {
        let usage = try XCTUnwrap(SubscriptionUsage(header: "upload=0; download=5; total=0; expire=0"))
        XCTAssertNil(usage.total)
        XCTAssertNil(usage.expiresAt)
        XCTAssertNil(usage.fractionUsed)
        XCTAssertNil(usage.daysLeft())
        XCTAssertNil(SubscriptionUsage(header: "nothing here"))
    }

    func testTitleAndInterval() {
        XCTAssertEqual(SubscriptionHeaders.title("base64:" + Fake.base64("Мой VPN")), "Мой VPN")
        XCTAssertEqual(SubscriptionHeaders.title("  Plain title "), "Plain title")
        XCTAssertNil(SubscriptionHeaders.title(""))
        XCTAssertNil(SubscriptionHeaders.title(nil))
        XCTAssertEqual(SubscriptionHeaders.updateIntervalHours("12"), 12)
        XCTAssertNil(SubscriptionHeaders.updateIntervalHours("0"))
        XCTAssertNil(SubscriptionHeaders.updateIntervalHours("soon"))
    }
}
