import Foundation

/// Parses share links: `vless://` and `hysteria2://` (`hy2://`).
///
/// Parsing is done by hand rather than with `URLComponents`: links often carry
/// unescaped names with spaces or emoji, which Foundation rejects differently
/// on macOS and Linux.
public enum ShareLinkParser {
    public static let supportedSchemes: Set<String> = ["vless", "hysteria2", "hy2"]

    public static func parse(_ raw: String) throws -> ServerConfig {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = link.range(of: "://") else {
            throw ImportError.malformedLink("нет схемы")
        }
        let scheme = link[..<schemeEnd.lowerBound].lowercased()
        let rest = String(link[schemeEnd.upperBound...])
        switch scheme {
        case "vless":
            return try parseVLESS(rest)
        case "hysteria2", "hy2":
            return try parseHysteria2(rest)
        default:
            throw ImportError.unsupportedScheme(scheme)
        }
    }

    /// Scheme of a link for error reports, without the secret part.
    public static func scheme(of link: String) -> String {
        guard let end = link.range(of: "://") else { return "?" }
        return link[..<end.lowerBound].lowercased()
    }

    // MARK: - VLESS

    private static func parseVLESS(_ rest: String) throws -> ServerConfig {
        let parts = try split(rest)
        guard !parts.userInfo.isEmpty else { throw ImportError.missingField("UUID") }
        guard let portText = parts.portText, let port = Int(portText), (1...65535).contains(port) else {
            throw ImportError.malformedLink("неверный порт")
        }
        let query = parts.query
        let transport = try transport(from: query["type"] ?? "tcp")

        let security: TransportSecurity
        switch (query["security"] ?? "none").lowercased() {
        case "", "none": security = .none
        case "tls", "xtls": security = .tls
        case "reality": security = .reality
        case let other: throw ImportError.unsupportedFormat("security=\(other)")
        }

        var reality: RealityOptions?
        if security == .reality {
            guard let publicKey = query["pbk"].nonEmpty else {
                throw ImportError.missingField("pbk (ключ Reality)")
            }
            reality = RealityOptions(publicKey: publicKey, shortID: query["sid"].nonEmpty, spiderX: query["spx"].nonEmpty)
        }

        let tls = TLSOptions(
            serverName: query["sni"].nonEmpty ?? query["peer"].nonEmpty,
            fingerprint: query["fp"].nonEmpty,
            alpn: list(query["alpn"]),
            allowInsecure: flag(query["allowInsecure"] ?? query["insecure"])
        )

        let settings = VLESSSettings(
            uuid: parts.userInfo,
            flow: query["flow"].nonEmpty,
            encryption: query["encryption"].nonEmpty,
            transport: transport,
            security: security,
            tls: tls,
            reality: reality,
            path: transport == .grpc ? nil : query["path"].nonEmpty,
            host: query["host"].nonEmpty,
            serviceName: transport == .grpc ? (query["serviceName"].nonEmpty ?? query["path"].nonEmpty) : nil,
            xhttpMode: transport == .xhttp ? query["mode"].nonEmpty : nil
        )
        return ServerConfig(
            name: parts.name.isEmpty ? "VLESS \(parts.host)" : parts.name,
            host: parts.host,
            port: port,
            settings: .vless(settings)
        )
    }

    static func transport(from raw: String) throws -> Transport {
        switch raw.lowercased() {
        case "", "tcp", "raw": return .tcp
        case "ws", "websocket": return .ws
        case "grpc", "gun": return .grpc
        case "xhttp", "splithttp": return .xhttp
        case "httpupgrade": return .httpupgrade
        default: throw ImportError.unsupportedTransport(raw)
        }
    }

    // MARK: - Hysteria2

    private static func parseHysteria2(_ rest: String) throws -> ServerConfig {
        let parts = try split(rest)
        guard !parts.userInfo.isEmpty else { throw ImportError.missingField("пароль") }
        let query = parts.query

        var port = 443
        var hopping: String?
        if let portText = parts.portText, !portText.isEmpty {
            if let single = Int(portText), (1...65535).contains(single) {
                port = single
            } else {
                // Port hopping: "443,20000-30000" — connect to the first port.
                let first = portText.split(whereSeparator: { $0 == "," || $0 == "-" }).first.flatMap { Int($0) }
                guard let first, (1...65535).contains(first) else {
                    throw ImportError.malformedLink("неверный порт")
                }
                port = first
                hopping = portText
            }
        }
        if let mport = query["mport"].nonEmpty { hopping = mport }

        let tls = TLSOptions(
            serverName: query["sni"].nonEmpty ?? query["peer"].nonEmpty,
            alpn: list(query["alpn"]),
            allowInsecure: flag(query["insecure"] ?? query["allowInsecure"]),
            pinnedCertSHA256: query["pinSHA256"].nonEmpty
        )
        let settings = Hysteria2Settings(
            auth: parts.userInfo,
            tls: tls,
            obfs: query["obfs"].nonEmpty,
            obfsPassword: query["obfs-password"].nonEmpty,
            portHopping: hopping
        )
        return ServerConfig(
            name: parts.name.isEmpty ? "Hysteria2 \(parts.host)" : parts.name,
            host: parts.host,
            port: port,
            settings: .hysteria2(settings)
        )
    }

    // MARK: - Splitting

    struct Parts {
        var userInfo: String
        var host: String
        var portText: String?
        var query: [String: String]
        var name: String
    }

    static func split(_ rest: String) throws -> Parts {
        var body = Substring(rest)

        var name = ""
        if let hash = body.firstIndex(of: "#") {
            let fragment = String(body[body.index(after: hash)...])
            name = (fragment.removingPercentEncoding ?? fragment).trimmingCharacters(in: .whitespacesAndNewlines)
            body = body[..<hash]
        }

        var query: [String: String] = [:]
        if let questionMark = body.firstIndex(of: "?") {
            for pair in body[body.index(after: questionMark)...].split(separator: "&") {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = decode(keyValue[0])
                let value = keyValue.count > 1 ? decode(keyValue[1]) : ""
                if !key.isEmpty, query[key] == nil { query[key] = value }
            }
            body = body[..<questionMark]
        }

        guard let at = body.lastIndex(of: "@") else { throw ImportError.missingField("пользователь") }
        let userInfo = decode(body[..<at])
        var hostPort = body[body.index(after: at)...]
        if let slash = hostPort.firstIndex(of: "/") { hostPort = hostPort[..<slash] }

        let host: String
        var portText: String?
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { throw ImportError.malformedLink("неверный IPv6-адрес") }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            if after.hasPrefix(":") { portText = String(after.dropFirst()) }
        } else if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colon])
            portText = String(hostPort[hostPort.index(after: colon)...])
        } else {
            host = String(hostPort)
        }
        guard !host.isEmpty else { throw ImportError.missingField("адрес сервера") }

        return Parts(userInfo: userInfo, host: host, portText: portText, query: query, name: name)
    }

    private static func decode<S: StringProtocol>(_ text: S) -> String {
        let string = String(text)
        return string.removingPercentEncoding ?? string
    }

    static func list(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func flag(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes"
    }
}

extension Optional where Wrapped == String {
    /// The value if it is non-empty after trimming, otherwise nil.
    var nonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
