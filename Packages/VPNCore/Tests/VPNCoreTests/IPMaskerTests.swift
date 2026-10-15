import XCTest
@testable import VPNCore

final class IPMaskerTests: XCTestCase {
    func testMasksIPv4() {
        XCTAssertEqual(IPMasker.mask("203.0.113.57"), "203.0.•••.•••")
    }

    func testMasksIPv6() {
        XCTAssertEqual(IPMasker.mask("2001:db8:85a3::8a2e:370:7334"), "2001:db8:•••")
    }

    func testFallsBackForGarbage() {
        XCTAssertEqual(IPMasker.mask("not-an-ip"), "•••")
    }
}
