import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VPNCore

final class IPLookupTests: XCTestCase {
    func testParsesIPInfo() throws {
        let json = """
        {"ip": "203.0.113.57", "city": "Amsterdam", "region": "North Holland", "country": "NL",
         "org": "AS64496 Example Hosting B.V.", "timezone": "Europe/Amsterdam"}
        """
        let info = try IPService.ipinfo.parse(Data(json.utf8))
        XCTAssertEqual(info, IPInfo(ip: "203.0.113.57", countryCode: "NL", city: "Amsterdam",
                                    organization: "Example Hosting B.V."))
    }

    func testParsesIfconfig() throws {
        let json = """
        {"ip": "2001:db8::1", "country": "Germany", "country_iso": "DE", "city": "Frankfurt",
         "asn": "AS64497", "asn_org": "Example Networks"}
        """
        let info = try IPService.ifconfig.parse(Data(json.utf8))
        XCTAssertEqual(info, IPInfo(ip: "2001:db8::1", countryCode: "DE", city: "Frankfurt",
                                    organization: "Example Networks"))
    }

    func testRejectsAnswersWithoutAValidIP() {
        for json in ["{}", "[]", "not json", #"{"ip": "<script>"}"#, #"{"ip": "1.2.3"}"#, #"{"ip": 42}"#] {
            XCTAssertThrowsError(try IPService.ipinfo.parse(Data(json.utf8)), json)
        }
    }

    func testCleansOddFields() throws {
        let json = #"{"ip": " 198.51.100.4 ", "country": "nl", "city": "A\u0007B", "org": "AS64496"}"#
        let info = try IPService.ipinfo.parse(Data(json.utf8))
        XCTAssertEqual(info.ip, "198.51.100.4")
        XCTAssertEqual(info.countryCode, "NL")
        XCTAssertEqual(info.city, "AB")
        XCTAssertEqual(info.organization, "AS64496")

        let bad = try IPService.ipinfo.parse(Data(#"{"ip": "198.51.100.4", "country": "Netherlands"}"#.utf8))
        XCTAssertNil(bad.countryCode)
    }

    func testChanged() {
        let home = IPInfo(ip: "203.0.113.57")
        let vpn = IPInfo(ip: "198.51.100.4")
        XCTAssertEqual(IPLookup.changed(direct: home, vpn: vpn), true)
        XCTAssertEqual(IPLookup.changed(direct: home, vpn: home), false)
        XCTAssertNil(IPLookup.changed(direct: home, vpn: nil))
    }

    func testRequestsGoOverHTTPS() {
        for service in IPService.allCases {
            XCTAssertEqual(service.url.scheme, "https")
            XCTAssertEqual(service.request().cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        }
    }
}

final class SpeedTestTests: XCTestCase {
    func testMegabitsPerSecond() {
        XCTAssertEqual(SpeedTest.megabitsPerSecond(bytes: 12_500_000, seconds: 1), 100, accuracy: 0.001)
        XCTAssertEqual(SpeedTest.megabitsPerSecond(bytes: 0, seconds: 1), 0)
        XCTAssertEqual(SpeedTest.megabitsPerSecond(bytes: 100, seconds: 0), 0)
    }

    func testMedian() {
        XCTAssertNil(SpeedTest.median([]))
        XCTAssertEqual(SpeedTest.median([30, 10, 20]), 20)
        XCTAssertEqual(SpeedTest.median([40, 10, 20, 30]), 25)
    }

    func testURLs() {
        XCTAssertEqual(SpeedTest.downloadURL(bytes: 1_000).absoluteString, "https://speed.cloudflare.com/__down?bytes=1000")
        XCTAssertEqual(SpeedTest.uploadRequest().httpMethod, "POST")
        XCTAssertEqual(SpeedTest.maxTrafficBytes, 35_000_000)
    }

    func testPingSort() {
        let ids = ["a", "b", "c", "d"]
        let pings = ["b": 40, "c": 200, "d": 40]
        XCTAssertEqual(PingSort.byPing(ids, pings: pings), ["b", "d", "c", "a"])
        XCTAssertEqual(PingSort.fastest(ids, pings: pings), "b")
        XCTAssertNil(PingSort.fastest(ids, pings: [:]))
    }

    func testPingQuality() {
        XCTAssertEqual(PingQuality(milliseconds: 50), .good)
        XCTAssertEqual(PingQuality(milliseconds: 150), .fair)
        XCTAssertEqual(PingQuality(milliseconds: 900), .poor)
    }

    func testResultRoundTrip() throws {
        let result = SpeedResult(route: .vpn, serverName: "NL-1", latencyMs: 42, downloadMbps: 95.5,
                                 uploadMbps: 40, bytesUsed: 1_000)
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(SpeedResult.self, from: data), result)
    }
}
