import Foundation

public enum CoreConfigError: Error, Equatable, Sendable {
    case noServers
    case unknownSelection
    case invalidPort(Int)
    case invalidSecret
    case invalidAppPath
    case tooManyEntries
    case invalidValue(String)

    public var message: String {
        switch self {
        case .noServers: "Нет серверов для подключения"
        case .unknownSelection: "Выбранный сервер не найден"
        case .invalidPort(let port): "Недопустимый порт \(port)"
        case .invalidSecret: "Недопустимый секрет API"
        case .invalidAppPath: "Недопустимый путь к программе"
        case .tooManyEntries: "Слишком много серверов или программ"
        case .invalidValue(let field): "Недопустимое значение в поле \(field)"
        }
    }
}

/// Builds the mihomo config. mihomo reads YAML, and JSON is valid YAML,
/// so the config is plain JSON from JSONSerialization: no string templating,
/// every value is escaped by the encoder.
///
/// Proxies are named by server id ("s-…") and groups by group id ("g-…"):
/// names from a subscription never reach the config.
public enum MihomoConfigBuilder {
    public static let proxyGroup = "PROXY"
    public static let appsProvider = "apps"
    public static let appsFileName = "apps.yaml"
    public static let testURL = "https://www.gstatic.com/generate_204"
    public static let appProcessName = "VPNforYou"

    static let maxServers = 500
    public static let maxApps = 500

    static let lanRanges = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
        "169.254.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10",
    ]

    // MARK: - Validation

    /// Checks everything the helper receives before it reaches the config.
    public static func validate(_ request: CoreStartRequest) throws {
        guard !request.servers.isEmpty else { throw CoreConfigError.noServers }
        guard request.servers.count <= maxServers, request.groups.count <= maxServers,
              request.appPaths.count <= maxApps
        else { throw CoreConfigError.tooManyEntries }

        let session = request.session
        for port in [session.controllerPort, session.mixedPort] where !(1024...65535).contains(port) {
            throw CoreConfigError.invalidPort(port)
        }
        guard session.controllerPort != session.mixedPort else { throw CoreConfigError.invalidPort(session.mixedPort) }
        for token in [session.controllerSecret, session.mixedPassword] {
            guard (16...128).contains(token.count), token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw CoreConfigError.invalidSecret
            }
        }
        guard (3...64).contains(session.mixedUser.count),
              session.mixedUser.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw CoreConfigError.invalidSecret }

        let serverIDs = Set(request.servers.map(\.id))
        let groupIDs = Set(request.groups.map(\.id))
        guard serverIDs.contains(request.selectedID) || groupIDs.contains(request.selectedID) else {
            throw CoreConfigError.unknownSelection
        }
        for group in request.groups where group.memberIDs.isEmpty || !group.memberIDs.allSatisfy(serverIDs.contains) {
            throw CoreConfigError.invalidValue("group")
        }
        for server in request.servers {
            guard (1...65535).contains(server.port) else { throw CoreConfigError.invalidPort(server.port) }
            guard isClean(server.host), !server.host.isEmpty else { throw CoreConfigError.invalidValue("server") }
            if case .hysteria2(let hy2) = server.settings, let hopping = hy2.portHopping,
               !hopping.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == "-") }) {
                throw CoreConfigError.invalidValue("ports")
            }
        }
        for path in request.appPaths {
            guard path.hasPrefix("/"), path.count <= 1024, isClean(path), !path.contains("/../") else {
                throw CoreConfigError.invalidAppPath
            }
        }
    }

    /// No control characters (newlines would break line-based rule files).
    static func isClean(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    // MARK: - Config

    /// The whole config as a JSON-compatible dictionary.
    /// - Parameter appsRulesPath: absolute path of the per-app rules file, written by the helper.
    public static func config(for request: CoreStartRequest, appsRulesPath: String) throws -> [String: Any] {
        try validate(request)
        let session = request.session

        var config: [String: Any] = [
            "mixed-port": session.mixedPort,
            "bind-address": "127.0.0.1",
            "allow-lan": false,
            "authentication": ["\(session.mixedUser):\(session.mixedPassword)"],
            "mode": "rule",
            "log-level": "warning",
            "ipv6": request.ipv6,
            "unified-delay": true,
            "tcp-concurrent": true,
            "find-process-mode": "always",
            "external-controller": "127.0.0.1:\(session.controllerPort)",
            "secret": session.controllerSecret,
            "geodata-mode": false,
            "geo-auto-update": false,
            "profile": ["store-selected": false, "store-fake-ip": false],
            "tun": [
                "enable": true,
                "stack": "mixed",
                "auto-route": true,
                "auto-detect-interface": true,
                "dns-hijack": ["any:53", "tcp://any:53"],
            ] as [String: Any],
            "dns": dns(ipv6: request.ipv6),
            "proxies": request.servers.map(proxy),
            "proxy-groups": proxyGroups(for: request),
            "rules": rules(for: request),
        ]
        if request.routing != .all {
            config["rule-providers"] = [
                appsProvider: [
                    "type": "file",
                    "behavior": "classical",
                    "format": "yaml",
                    "path": appsRulesPath,
                ],
            ]
        }
        return config
    }

    public static func configData(for request: CoreStartRequest, appsRulesPath: String) throws -> Data {
        // mihomo parses the file as YAML, which rejects the JSON escape "\/".
        try JSONSerialization.data(
            withJSONObject: config(for: request, appsRulesPath: appsRulesPath),
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        )
    }

    static func dns(ipv6: Bool) -> [String: Any] {
        let doh = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
        return [
            "enable": true,
            "ipv6": ipv6,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "fake-ip-filter": [
                "*.lan", "*.local", "*.localdomain", "*.home.arpa", "localhost",
                "time.*.com", "+.ntp.org", "+.pool.ntp.org", "time.apple.com",
                "+.msftconnecttest.com", "+.msftncsi.com",
            ],
            "default-nameserver": ["1.1.1.1", "8.8.8.8"],
            "nameserver": doh,
            "proxy-server-nameserver": doh,
        ]
    }

    static func proxyGroups(for request: CoreStartRequest) -> [[String: Any]] {
        var groups: [[String: Any]] = request.groups.map { group in
            [
                "name": group.id,
                "type": "url-test",
                "proxies": group.memberIDs,
                "url": testURL,
                "interval": 300,
                "tolerance": 50,
                "lazy": true,
            ]
        }
        // The selector lists the chosen entry first, so it is the default.
        var choices = [request.selectedID]
        choices += request.groups.map(\.id).filter { $0 != request.selectedID }
        choices += request.servers.map(\.id).filter { $0 != request.selectedID }
        groups.append(["name": proxyGroup, "type": "select", "proxies": choices])
        return groups
    }

    static func rules(for request: CoreStartRequest) -> [String] {
        var rules = [
            // The app's own speed and IP checks "through VPN" use the local proxy port.
            "IN-PORT,\(request.session.mixedPort),\(proxyGroup)",
            // Everything else from the app itself (IP "without VPN", subscriptions) goes direct.
            "PROCESS-NAME,\(appProcessName),DIRECT",
        ]
        rules += lanRanges.map { "IP-CIDR\($0.contains(":") ? "6" : ""),\($0),DIRECT,no-resolve" }
        switch request.routing {
        case .all:
            rules.append("MATCH,\(proxyGroup)")
        case .onlySelected:
            rules.append("RULE-SET,\(appsProvider),\(proxyGroup)")
            rules.append("MATCH,DIRECT")
        case .allExceptSelected:
            rules.append("RULE-SET,\(appsProvider),DIRECT")
            rules.append("MATCH,\(proxyGroup)")
        }
        return rules
    }

    // MARK: - Proxies

    static func proxy(_ server: ServerConfig) -> [String: Any] {
        var proxy: [String: Any] = [
            "name": server.id,
            "server": server.host,
            "port": server.port,
            "udp": true,
        ]
        switch server.settings {
        case .vless(let vless):
            proxy["type"] = "vless"
            proxy["uuid"] = vless.uuid
            if let flow = vless.flow { proxy["flow"] = flow }
            if let encryption = vless.encryption, encryption != "none" { proxy["encryption"] = encryption }
            proxy["network"] = network(vless.transport)
            if vless.security != .none {
                proxy["tls"] = true
                if let serverName = vless.tls.serverName { proxy["servername"] = serverName }
                proxy["client-fingerprint"] = vless.tls.fingerprint ?? "chrome"
                if !vless.tls.alpn.isEmpty { proxy["alpn"] = vless.tls.alpn }
                if vless.tls.allowInsecure { proxy["skip-cert-verify"] = true }
            }
            if let reality = vless.reality {
                var options: [String: Any] = ["public-key": reality.publicKey]
                if let shortID = reality.shortID { options["short-id"] = shortID }
                proxy["reality-opts"] = options
            }
            switch vless.transport {
            case .tcp:
                break
            case .ws, .httpupgrade:
                var options: [String: Any] = ["path": vless.path ?? "/"]
                if let host = vless.host { options["headers"] = ["Host": host] }
                if vless.transport == .httpupgrade { options["v2ray-http-upgrade"] = true }
                proxy["ws-opts"] = options
            case .grpc:
                proxy["grpc-opts"] = ["grpc-service-name": vless.serviceName ?? ""]
            case .xhttp:
                var options: [String: Any] = ["path": vless.path ?? "/"]
                if let host = vless.host { options["host"] = host }
                if let mode = vless.xhttpMode { options["mode"] = mode }
                proxy["xhttp-opts"] = options
            }
        case .hysteria2(let hy2):
            proxy["type"] = "hysteria2"
            proxy["password"] = hy2.auth
            if let serverName = hy2.tls.serverName { proxy["sni"] = serverName }
            if !hy2.tls.alpn.isEmpty { proxy["alpn"] = hy2.tls.alpn }
            if hy2.tls.allowInsecure { proxy["skip-cert-verify"] = true }
            // mihomo refuses the whole config if a pin is not a full SHA-256,
            // so a malformed pin is dropped (normal certificate checks still apply).
            if let pin = hy2.tls.pinnedCertSHA256.flatMap(normalizedSHA256) {
                proxy["fingerprint"] = pin
            }
            if let obfs = hy2.obfs { proxy["obfs"] = obfs }
            if let obfsPassword = hy2.obfsPassword { proxy["obfs-password"] = obfsPassword }
            if let ports = hy2.portHopping { proxy["ports"] = ports }
        }
        return proxy
    }

    /// 64 lower-case hex characters, or nil.
    static func normalizedSHA256(_ text: String) -> String? {
        let hex = text.replacingOccurrences(of: ":", with: "").lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    static func network(_ transport: Transport) -> String {
        switch transport {
        case .tcp: "tcp"
        case .ws, .httpupgrade: "ws"
        case .grpc: "grpc"
        case .xhttp: "xhttp"
        }
    }

    // MARK: - Per-app rules

    /// Rule-provider file for the selected apps: every process inside the bundle
    /// (helpers included) matches `^<path>/`.
    public static func appsRules(paths: [String]) -> String {
        var lines = ["payload:"]
        if paths.isEmpty {
            // An empty provider is rejected; this rule never matches a real process.
            lines.append("  - 'PROCESS-NAME,vpnforyou-no-apps-selected'")
        }
        for path in paths {
            let bundle = path.hasSuffix("/") ? path : path + "/"
            lines.append("  - '" + "PROCESS-PATH-REGEX,^" + regexEscape(bundle) + "'")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes RE2 metacharacters. Commas separate rule fields, so they become
    /// `\x2C`; single quotes would end the YAML scalar, so they become `\x27`.
    static func regexEscape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$":
                result += "\\" + String(character)
            case ",":
                result += "\\x2C"
            case "'":
                result += "\\x27"
            default:
                result.append(character)
            }
        }
        return result
    }
}
