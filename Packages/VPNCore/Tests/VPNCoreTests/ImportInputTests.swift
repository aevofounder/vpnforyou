import XCTest
@testable import VPNCore

final class ImportInputTests: XCTestCase {
    func testMixedPaste() {
        let text = """
        https://sub.example.com/s/fake-token
        \(Fake.vlessReality)
        \(Fake.hysteria2)
        https://sub.example.com/s/fake-token
        """
        let input = ImportInput.classify(text)
        XCTAssertEqual(input.subscriptionURLs, ["https://sub.example.com/s/fake-token"])
        XCTAssertEqual(input.parsed.servers.count, 2)
    }

    func testOnlySubscription() {
        let input = ImportInput.classify("  https://sub.example.com/s/fake-token  ")
        XCTAssertEqual(input.subscriptionURLs.count, 1)
        XCTAssertTrue(input.parsed.isEmpty)
        XCTAssertFalse(input.isEmpty)
    }

    func testGarbage() {
        let input = ImportInput.classify("привет")
        XCTAssertTrue(input.subscriptionURLs.isEmpty)
        XCTAssertTrue(input.parsed.isEmpty)
        XCTAssertEqual(input.parsed.skipped.count, 1)
    }
}
