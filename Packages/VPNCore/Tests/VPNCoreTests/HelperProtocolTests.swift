import Foundation
import XCTest
@testable import VPNCore

final class HelperProtocolTests: XCTestCase {
    func testShellQuoting() {
        XCTAssertEqual(HelperInstallScript.shellQuote("/Applications/VPN for You.app"), "'/Applications/VPN for You.app'")
        XCTAssertEqual(HelperInstallScript.shellQuote("a'b"), #"'a'\''b'"#)
        XCTAssertEqual(HelperInstallScript.shellQuote("$(rm -rf ~)`x`"), "'$(rm -rf ~)`x`'")
    }

    func testInstallScriptQuotesEveryPath() {
        let script = HelperInstallScript.install(executables: "/Users/me/Down loads/VPN'forYou.app/Contents/MacOS", plistFile: "/tmp/x y.plist")
        XCTAssertTrue(script.hasPrefix("set -e\n"))
        XCTAssertTrue(script.contains(#"install -o root -g wheel -m 755 '/Users/me/Down loads/VPN'\''forYou.app/Contents/MacOS/vpnforyou-helper' '/Library/PrivilegedHelperTools/io.github.aevofounder.vpnforyou.helper'"#))
        XCTAssertTrue(script.contains("'/Library/Application Support/VPNforYou/mihomo'"))
        XCTAssertTrue(script.contains("launchctl bootstrap system '/Library/LaunchDaemons/io.github.aevofounder.vpnforyou.helper.plist'"))
    }

    func testAppleScriptEscaping() {
        let apple = HelperInstallScript.appleScript(shell: "echo \"a\\b\"\nls", prompt: "Пароль")
        XCTAssertEqual(apple, #"do shell script "echo \"a\\b\"\nls" with prompt "Пароль" with administrator privileges"#)
    }

    func testLaunchdPlist() throws {
        let data = try HelperProtocol.launchdPlist(allowedUID: 501)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, HelperProtocol.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [HelperProtocol.helperPath, "--allowed-uid", "501"])
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    }

    func testRequestRoundTrip() throws {
        let request = HelperRequest(command: .setApps, apps: AppsUpdate(paths: ["/Applications/Telegram.app"]))
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
    }
}
