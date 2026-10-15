import Foundation

/// Paths and wire format shared by the app and the privileged helper.
///
/// The helper runs as root (a LaunchDaemon). It listens on a Unix socket that
/// only the installing user can open, accepts typed commands and builds the
/// mihomo config itself. It never executes anything from a user-writable place:
/// the core binary is copied into a root-owned folder at install time.
public enum HelperProtocol {
    /// Bump when the request/response format or the helper's behaviour changes;
    /// the app then offers to reinstall the helper.
    public static let version = "1"

    public static let label = "io.github.aevofounder.vpnforyou.helper"
    public static let socketPath = "/var/run/io.github.aevofounder.vpnforyou.helper.sock"
    public static let helperPath = "/Library/PrivilegedHelperTools/io.github.aevofounder.vpnforyou.helper"
    public static let plistPath = "/Library/LaunchDaemons/io.github.aevofounder.vpnforyou.helper.plist"
    public static let supportDirectory = "/Library/Application Support/VPNforYou"
    public static let corePath = supportDirectory + "/mihomo"
    public static let runDirectory = supportDirectory + "/run"
    public static let logPath = "/Library/Logs/VPNforYou-helper.log"

    /// Names of the bundled executables inside VPNforYou.app/Contents/MacOS.
    public static let bundledHelperName = "vpnforyou-helper"
    public static let bundledCoreName = "mihomo"

    public static let maxMessageSize = 4 * 1024 * 1024

    /// launchd job: starts at boot, restarted if it exits, allowed only for one user.
    public static func launchdPlist(allowedUID: UInt32) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperPath, "--allowed-uid", String(allowedUID)],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardErrorPath": logPath,
            "StandardOutPath": logPath,
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

public struct AppsUpdate: Codable, Equatable, Sendable {
    public var paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}

public struct HelperRequest: Codable, Equatable, Sendable {
    public enum Command: String, Codable, Sendable {
        case hello, start, stop, status, setApps, logs
    }

    public var command: Command
    public var start: CoreStartRequest?
    public var apps: AppsUpdate?

    public init(command: Command, start: CoreStartRequest? = nil, apps: AppsUpdate? = nil) {
        self.command = command
        self.start = start
        self.apps = apps
    }
}

public struct HelperResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var helperVersion: String?
    public var running: Bool?
    public var logs: [String]?

    public init(ok: Bool, error: String? = nil, helperVersion: String? = nil, running: Bool? = nil, logs: [String]? = nil) {
        self.ok = ok
        self.error = error
        self.helperVersion = helperVersion
        self.running = running
        self.logs = logs
    }

    public static func failure(_ message: String) -> HelperResponse {
        HelperResponse(ok: false, error: message, helperVersion: HelperProtocol.version)
    }
}

/// Shell and AppleScript text for installing and removing the helper with
/// `do shell script … with administrator privileges`.
public enum HelperInstallScript {
    /// Copies the helper and the core into root-owned places and (re)loads the daemon.
    /// - Parameters:
    ///   - executables: VPNforYou.app/Contents/MacOS of the running app.
    ///   - plistFile: a temporary file with `HelperProtocol.launchdPlist`.
    public static func install(executables: String, plistFile: String) -> String {
        let helper = shellQuote(executables + "/" + HelperProtocol.bundledHelperName)
        let core = shellQuote(executables + "/" + HelperProtocol.bundledCoreName)
        let label = HelperProtocol.label
        return [
            "set -e",
            "install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
            "install -o root -g wheel -m 755 \(helper) \(shellQuote(HelperProtocol.helperPath))",
            "install -d -o root -g wheel -m 755 \(shellQuote(HelperProtocol.supportDirectory))",
            "install -o root -g wheel -m 755 \(core) \(shellQuote(HelperProtocol.corePath))",
            "install -o root -g wheel -m 644 \(shellQuote(plistFile)) \(shellQuote(HelperProtocol.plistPath))",
            "launchctl bootout system/\(label) 2>/dev/null || true",
            "launchctl bootstrap system \(shellQuote(HelperProtocol.plistPath))",
        ].joined(separator: "\n")
    }

    /// Stops the daemon and removes everything the installer put in place.
    public static func uninstall() -> String {
        [
            "launchctl bootout system/\(HelperProtocol.label) 2>/dev/null || true",
            "rm -f \(shellQuote(HelperProtocol.plistPath)) \(shellQuote(HelperProtocol.helperPath)) \(shellQuote(HelperProtocol.socketPath))",
            "rm -rf \(shellQuote(HelperProtocol.supportDirectory))",
        ].joined(separator: "\n")
    }

    /// AppleScript that runs `shell` as root after the system password prompt.
    public static func appleScript(shell: String, prompt: String) -> String {
        "do shell script \"\(appleScriptEscape(shell))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"
    }

    /// Single-quoted shell word: safe for spaces, $, `, " and backslashes.
    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes for an AppleScript string literal; line breaks become `\n`.
    public static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
