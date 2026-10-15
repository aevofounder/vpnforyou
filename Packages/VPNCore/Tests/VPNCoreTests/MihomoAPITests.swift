import Foundation
import XCTest
@testable import VPNCore

final class MihomoAPITests: XCTestCase {
    private let session = CoreSession(controllerPort: 29_090, controllerSecret: String(repeating: "c", count: 32),
                                      mixedPort: 29_091, mixedUser: "vfytest", mixedPassword: String(repeating: "d", count: 32))

    func testRequests() throws {
        let api = MihomoAPI(session: session)
        XCTAssertEqual(api.version.url?.absoluteString, "http://127.0.0.1:29090/version")
        XCTAssertEqual(api.version.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "c", count: 32))

        let select = api.select("s-0011")
        XCTAssertEqual(select.httpMethod, "PUT")
        XCTAssertEqual(select.url?.path, "/proxies/PROXY")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: select.httpBody ?? Data()) as? [String: String], ["name": "s-0011"])

        let delay = api.delay("g-ab")
        XCTAssertEqual(delay.url?.path, "/proxies/g-ab/delay")
        XCTAssertTrue(delay.url?.query?.contains("timeout=5000") == true)
        XCTAssertEqual(api.reloadApps.url?.path, "/providers/rules/apps")
    }

    func testTrafficLine() {
        XCTAssertEqual(TrafficSample.parse(line: #"{"up":10,"down":2048,"upTotal":1,"downTotal":5}"#),
                       TrafficSample(up: 10, down: 2048, upTotal: 1, downTotal: 5))
        XCTAssertNil(TrafficSample.parse(line: "garbage"))
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
