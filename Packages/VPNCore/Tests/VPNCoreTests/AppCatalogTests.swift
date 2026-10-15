import Foundation
import XCTest
@testable import VPNCore

final class AppCatalogTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func makeApp(_ relativePath: String, bundleID: String?) throws {
        let contents = (root as NSString).appendingPathComponent(relativePath + "/Contents")
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        guard let bundleID else { return }
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "Ignored"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: contents + "/Info.plist"))
    }

    func testScanFindsAppsOneLevelDeepAndSkipsTheRest() throws {
        try makeApp("Telegram.app", bundleID: "org.example.telegram")
        try makeApp("Utilities/Console.app", bundleID: "com.example.console")
        try makeApp("Deep/Deeper/Hidden.app", bundleID: "com.example.hidden")
        try makeApp(".Secret.app", bundleID: "com.example.secret")
        try makeApp("VPNforYou.app", bundleID: AppCatalog.ownBundleID)
        try makeApp("NoPlist.app", bundleID: nil)
        try Data().write(to: URL(fileURLWithPath: root + "/notes.txt"))

        let apps = AppCatalog.scan(roots: [root, root + "/missing"])
        XCTAssertEqual(apps.map(\.name), ["Console", "NoPlist", "Telegram"])
        XCTAssertEqual(apps.first { $0.name == "Telegram" }?.bundleID, "org.example.telegram")
        XCTAssertNil(apps.first { $0.name == "NoPlist" }?.bundleID)
        XCTAssertTrue(apps.allSatisfy { $0.path.hasPrefix("/") && $0.path.hasSuffix(".app") })
    }

    func testSymlinksResolveToOneEntry() throws {
        try makeApp("Real/Browser.app", bundleID: "org.example.browser")
        try FileManager.default.createSymbolicLink(atPath: root + "/Browser.app", withDestinationPath: root + "/Real/Browser.app")

        let apps = AppCatalog.scan(roots: [root])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.path, AppCatalog.normalize(root + "/Real/Browser.app"))
        XCTAssertEqual(apps.first?.name, "Browser")
    }

    func testNormalize() {
        XCTAssertNil(AppCatalog.normalize("relative/App.app"))
        XCTAssertNil(AppCatalog.normalize("/Applications/NotAnApp"))
        XCTAssertNil(AppCatalog.normalize("/Applications/Bad\nName.app"))
        XCTAssertEqual(AppCatalog.normalize("/nonexistent-root/./Apps/../Apps/Some App.app/"), "/nonexistent-root/Apps/Some App.app")
    }

    func testSystemNetworkingApps() {
        XCTAssertTrue(AppEntry(path: "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari").usesSystemNetworking)
        XCTAssertFalse(AppEntry(path: "/Applications/Telegram.app", name: "Telegram", bundleID: "org.example.telegram").usesSystemNetworking)
    }

    func testActivityGroupsByApp() {
        func row(_ id: String, _ app: String, _ path: String?, _ host: String, direct: Bool, down: Int64) -> ConnectionRates.Row {
            ConnectionRates.Row(id: id, appName: app, appPath: path, destination: host, isDirect: direct,
                                downPerSecond: down, upPerSecond: 0)
        }
        let rows = [
            row("1", "Browser", "/Applications/Browser.app", "www.example.com", direct: false, down: 100),
            row("2", "Browser", "/Applications/Browser.app", "cdn.example.net", direct: true, down: 50),
            row("3", "Chat", "/Applications/Chat.app", "chat.example.org", direct: false, down: 500),
            row("4", "mDNSResponder", nil, "203.0.113.1", direct: true, down: 0),
            row("5", "Browser", "/Applications/Browser.app", "www.example.com", direct: false, down: 0),
        ]
        let apps = ActivitySummary.byApp(rows)
        XCTAssertEqual(apps.map(\.name), ["Chat", "Browser", "mDNSResponder"])
        let browser = apps[1]
        XCTAssertEqual(browser.connections, 3)
        XCTAssertEqual(browser.viaVPN, 2)
        XCTAssertEqual(browser.direct, 1)
        XCTAssertTrue(browser.isMixed)
        XCTAssertEqual(browser.downPerSecond, 150)
        XCTAssertEqual(browser.destinations, ["www.example.com", "cdn.example.net"])
    }
}
