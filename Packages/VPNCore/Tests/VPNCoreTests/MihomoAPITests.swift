import Foundation
import XCTest
@testable import VPNCore

final class MihomoAPITests: XCTestCase {
    func testRequests() throws {
        XCTAssertEqual(MihomoRequest.version, MihomoRequest(method: "GET", path: "/version"))

        let select = MihomoRequest.select("s-0011")
        XCTAssertEqual(select.method, "PUT")
        XCTAssertEqual(select.path, "/proxies/PROXY")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: select.body ?? Data()) as? [String: String], ["name": "s-0011"])

        let delay = MihomoRequest.delay("g-ab")
        XCTAssertEqual(delay.path, "/proxies/g-ab/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000")
        XCTAssertEqual(MihomoRequest.delay("a b/../c").path.components(separatedBy: "?").first, "/proxies/a%20b%2F..%2Fc/delay")
        XCTAssertEqual(MihomoRequest.reloadApps, MihomoRequest(method: "PUT", path: "/providers/rules/apps"))
    }

    func testTrafficRateFromTotals() {
        let rate = TrafficTotals.rate(from: TrafficTotals(upload: 1_000, download: 10_000),
                                      to: TrafficTotals(upload: 3_000, download: 50_000), seconds: 2)
        XCTAssertEqual(rate, TrafficSample(up: 1_000, down: 20_000))
        // A restarted core starts counting from zero again: no negative speed.
        XCTAssertEqual(TrafficTotals.rate(from: TrafficTotals(upload: 9, download: 9),
                                          to: TrafficTotals(upload: 0, download: 0), seconds: 1), TrafficSample(up: 0, down: 0))
    }

    func testSnapshotRoundTripKeepsOnlyKnownFields() throws {
        let raw = #"{"downloadTotal":5,"uploadTotal":6,"connections":[{"id":"a","metadata":{"host":"api.example.com","sourceIP":"192.0.2.1","processPath":"/Applications/Chat.app/Contents/MacOS/Chat"},"upload":1,"download":2,"chains":["PROXY"],"extra":"x"}]}"#
        let snapshot = try ConnectionsSnapshot.parse(Data(raw.utf8))
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sourceIP"))
        XCTAssertFalse(encoded.contains("extra"))
        XCTAssertEqual(try JSONDecoder().decode(ConnectionsSnapshot.self, from: Data(encoded.utf8)), snapshot)
    }

    func testConnectionsAndRates() throws {
        XCTAssertEqual(try ConnectionsSnapshot.parse(Data(#"{"downloadTotal":0,"uploadTotal":0,"connections":null}"#.utf8)).connections, [])

        func snapshot(download: Int64) -> Data {
            Data("""
            {"downloadTotal":\(download),"uploadTotal":10,"connections":[
              {"id":"a","metadata":{"network":"tcp","host":"api.example.com","destinationIP":"203.0.113.9",
               "process":"Telegram","processPath":"/Applications/Telegram.app/Contents/MacOS/Telegram"},
               "upload":10,"download":\(download),"start":"2026-10-15T20:00:00Z","chains":["s-1","PROXY"],"rule":"RuleSet"},
              {"id":"b","metadata":{"network":"udp","host":"","destinationIP":"198.51.100.4","process":"mDNSResponder","processPath":"/usr/sbin/mDNSResponder"},
               "upload":0,"download":0,"start":"2026-10-15T20:00:00Z","chains":["DIRECT"],"rule":"Match"}
            ]}
            """.utf8)
        }
        let first = try ConnectionsSnapshot.parse(snapshot(download: 1_000))
        let second = try ConnectionsSnapshot.parse(snapshot(download: 3_000))
        let telegram = try XCTUnwrap(first.connections.first)
        XCTAssertEqual(telegram.appName, "Telegram")
        XCTAssertEqual(telegram.appBundlePath, "/Applications/Telegram.app")
        XCTAssertFalse(telegram.isDirect)
        XCTAssertEqual(first.connections[1].appName, "mDNSResponder")
        XCTAssertEqual(first.connections[1].destination, "198.51.100.4")
        XCTAssertTrue(first.connections[1].isDirect)

        let rows = ConnectionRates.rows(previous: first, current: second, interval: 2)
        XCTAssertEqual(rows.first?.appName, "Telegram")
        XCTAssertEqual(rows.first?.downPerSecond, 1_000)
    }
}
