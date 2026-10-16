import XCTest
@testable import VPNCore

final class ProfileTests: XCTestCase {
    private func sampleProfile() throws -> Profile {
        let parsed = try SubscriptionDecoder.decode(text: Fake.vlessReality + "\n" + Fake.hysteria2)
        return Profile(
            name: "sub.example.com",
            source: .subscription(url: "https://sub.example.com/s/fake-token"),
            servers: parsed.servers,
            usage: SubscriptionUsage(upload: 1, download: 2, total: 10, expiresAt: nil),
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    func testStoreRoundTrip() throws {
        let store = ProfileStore(secrets: InMemorySecretStore())
        XCTAssertEqual(try store.load(), [])
        let profiles = [try sampleProfile(), Profile(name: "Мои ключи", source: .manual)]
        try store.save(profiles)
        XCTAssertEqual(try store.load(), profiles)
    }

    func testNeedsRefresh() throws {
        var profile = try sampleProfile()
        let updated = try XCTUnwrap(profile.updatedAt)
        XCTAssertFalse(profile.needsRefresh(now: updated.addingTimeInterval(3_600)))
        XCTAssertTrue(profile.needsRefresh(now: updated.addingTimeInterval(13 * 3_600)))
        profile.updateIntervalHours = 1
        XCTAssertTrue(profile.needsRefresh(now: updated.addingTimeInterval(3_601)))
        profile.updatedAt = nil
        XCTAssertTrue(profile.needsRefresh())
        XCTAssertFalse(Profile(name: "Мои ключи", source: .manual).needsRefresh())
    }

    func testApplyAndMerge() throws {
        var profile = try sampleProfile()
        let fresh = try SubscriptionDecoder.decode(text: Fake.hysteria2)
        let now = Date(timeIntervalSince1970: 2_000_000)
        profile.apply(FetchedSubscription(parsed: fresh, usage: nil, title: "Мой VPN", updateIntervalHours: 6), now: now)
        XCTAssertEqual(profile.name, "Мой VPN")
        XCTAssertEqual(profile.servers.count, 1)
        XCTAssertNil(profile.usage)
        XCTAssertEqual(profile.updatedAt, now)
        XCTAssertEqual(profile.updateIntervalHours, 6)

        var manual = Profile(name: "Мои ключи", source: .manual)
        manual.merge(try SubscriptionDecoder.decode(text: Fake.vlessReality))
        manual.merge(try SubscriptionDecoder.decode(text: Fake.vlessReality + "\n" + Fake.hysteria2))
        XCTAssertEqual(manual.servers.count, 2)
    }
}
