import XCTest
@testable import VPNCore

final class CountryDetectorTests: XCTestCase {
    func testDetection() {
        let cases: [(String, String?)] = [
            ("🇫🇮 Helsinki", "FI"),
            ("LTE-Нидерланды", "NL"),
            ("AUTO-Германия", "DE"),
            ("Германии сервер", "DE"),
            ("USA East", "US"),
            ("NL-1", "NL"),
            ("UK-2", "GB"),
            ("London fast", "GB"),
            ("Нью-Йорк", "US"),
            ("Автовыбор", nil),
            ("Автовыбор-2", nil),
            ("Задание на загрузку", nil),
            ("Индивидуальный", nil),
        ]
        for (name, code) in cases {
            XCTAssertEqual(CountryDetector.detect(in: name), code, name)
        }
    }

    func testStripFlags() {
        XCTAssertEqual(CountryDetector.stripFlags("🇳🇱  Нидерланды"), "Нидерланды")
        XCTAssertEqual(CountryDetector.stripFlags("Без флага"), "Без флага")
    }
}
