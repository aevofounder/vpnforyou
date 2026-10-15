import Foundation

/// Parses Xray JSON subscriptions: an array of full Xray configs (or one config),
/// each with "remarks" and "outbounds". A config with several proxy outbounds
/// and a routing balancer becomes an auto-select group ("Автовыбор").
public enum XrayJSONParser {
    private static let serviceProtocols: Set<String> = ["freedom", "blackhole", "dns", "loopback"]

    public static func parse(_ data: Data) throws -> ParsedSubscription {
        let root = try JSONSerialization.jsonObject(with: data)
        let configs: [[String: Any]]
        if let array = root as? [[String: Any]] {
            configs = array
        } else if let object = root as? [String: Any] {
            configs = [object]
        } else {
            throw ImportError.unrecognizedFormat
        }

        // Pass 1: one proxy outbound per config — ordinary servers.
        // Pass 2: several outbounds — groups; their members stay hidden
        // unless the same server is also listed on its own.
        var result = ParsedSubscription()
        var multi: [(name: String, outbounds: [[String: Any]])] = []

        for (index, config) in configs.enumerated() {
            let name = (config["remarks"] as? String).nonEmpty ?? "Сервер \(index + 1)"
            let outbounds = (config["outbounds"] as? [[String: Any]] ?? []).filter { outbound in
                let proto = (outbound["protocol"] as? String ?? "").lowercased()
                if proto.isEmpty || serviceProtocols.contains(proto) { return false }
                if proto != "vless" && proto != "hysteria" {
                    result.skipped.append(SkippedEntry(name: name, reason: ImportError.unsupportedScheme(proto).message))
                    return false
                }
                return true
            }
            if outbounds.count == 1 {
                do {
                    result.add(try server(from: outbounds[0], name: name, hidden: false))
                } catch let error as ImportError {
                    result.skipped.append(SkippedEntry(name: name, reason: error.message))
                }
            } else if outbounds.count > 1 {
                multi.append((name, outbounds))
            }
        }

        for (name, outbounds) in multi {
            var memberIDs: [String] = []
            for (index, outbound) in outbounds.enumerated() {
                let memberName = "\(name) · \((outbound["tag"] as? String).nonEmpty ?? String(index + 1))"
                do {
                    let id = result.add(try server(from: outbound, name: memberName, hidden: true))
                    if !memberIDs.contains(id) { memberIDs.append(id) }
                } catch let error as ImportError {
                    result.skipped.append(SkippedEntry(name: memberName, reason: error.message))
                }
            }
            if !memberIDs.isEmpty {
                result.groups.append(ServerGroup(name: name, memberIDs: memberIDs))
            }
        }
        return result
    }

    static func server(from outbound: [String: Any], name: String, hidden: Bool) throws -> ServerConfig {
        let proto = (outbound["protocol"] as? String ?? "").lowercased()
        let settings = outbound["settings"] as? [String: Any] ?? [:]
        let stream = outbound["streamSettings"] as? [String: Any] ?? [:]
        let security = ((stream["security"] as? String) ?? "none").lowercased()
        let tlsSettings = stream["tlsSettings"] as? [String: Any] ?? [:]
        let realitySettings = stream["realitySettings"] as? [String: Any] ?? [:]

        switch proto {
        case "vless":
            var address = settings["address"] as? String
            var port = int(settings["port"])
            var user = settings
            if address == nil, let vnext = (settings["vnext"] as? [[String: Any]])?.first {
                address = vnext["address"] as? String
                port = int(vnext["port"])
                user = (vnext["users"] as? [[String: Any]])?.first ?? [:]
            }
            guard let host = address.nonEmpty else { throw ImportError.missingField("address") }
            guard let port, (1...65535).contains(port) else { throw ImportError.malformedLink("неверный порт") }
            guard let uuid = (user["id"] as? String).nonEmpty else { throw ImportError.missingField("id") }

            let transport = try ShareLinkParser.transport(from: (stream["network"] as? String) ?? "tcp")
            let transportSecurity: TransportSecurity
            switch security {
            case "", "none": transportSecurity = .none
            case "tls": transportSecurity = .tls
            case "reality": transportSecurity = .reality
            default: throw ImportError.unsupportedFormat("security=\(security)")
            }

            var reality: RealityOptions?
            if transportSecurity == .reality {
                guard let publicKey = (realitySettings["publicKey"] as? String).nonEmpty
                    ?? (realitySettings["password"] as? String).nonEmpty
                else { throw ImportError.missingField("publicKey (ключ Reality)") }
                reality = RealityOptions(
                    publicKey: publicKey,
                    shortID: (realitySettings["shortId"] as? String).nonEmpty,
                    spiderX: (realitySettings["spiderX"] as? String).nonEmpty
                )
            }

            var path: String?
            var hostHeader: String?
            var serviceName: String?
            var mode: String?
            switch transport {
            case .ws:
                let ws = stream["wsSettings"] as? [String: Any] ?? [:]
                path = (ws["path"] as? String).nonEmpty
                hostHeader = (ws["host"] as? String).nonEmpty
                    ?? ((ws["headers"] as? [String: Any])?["Host"] as? String).nonEmpty
            case .grpc:
                let grpc = stream["grpcSettings"] as? [String: Any] ?? [:]
                serviceName = (grpc["serviceName"] as? String).nonEmpty
            case .xhttp:
                let xhttp = stream["xhttpSettings"] as? [String: Any]
                    ?? stream["splithttpSettings"] as? [String: Any] ?? [:]
                path = (xhttp["path"] as? String).nonEmpty
                hostHeader = (xhttp["host"] as? String).nonEmpty
                mode = (xhttp["mode"] as? String).nonEmpty
            case .httpupgrade:
                let upgrade = stream["httpupgradeSettings"] as? [String: Any] ?? [:]
                path = (upgrade["path"] as? String).nonEmpty
                hostHeader = (upgrade["host"] as? String).nonEmpty
            case .tcp:
                break
            }

            let vless = VLESSSettings(
                uuid: uuid,
                flow: (user["flow"] as? String).nonEmpty,
                encryption: (user["encryption"] as? String).nonEmpty,
                transport: transport,
                security: transportSecurity,
                tls: tlsOptions(transportSecurity == .reality ? realitySettings : tlsSettings),
                reality: reality,
                path: path,
                host: hostHeader,
                serviceName: serviceName,
                xhttpMode: mode
            )
            return ServerConfig(name: name, host: host, port: port, settings: .vless(vless), isHidden: hidden ? true : nil)

        case "hysteria":
            if let version = int(settings["version"]), version != 2 {
                throw ImportError.unsupportedFormat("Hysteria v\(version)")
            }
            guard let host = (settings["address"] as? String).nonEmpty else { throw ImportError.missingField("address") }
            guard let port = int(settings["port"]), (1...65535).contains(port) else {
                throw ImportError.malformedLink("неверный порт")
            }
            let hysteria = stream["hysteriaSettings"] as? [String: Any] ?? [:]
            guard let auth = (hysteria["auth"] as? String).nonEmpty else { throw ImportError.missingField("auth") }

            var obfs: String?
            var obfsPassword: String?
            let udpMasks = (stream["finalmask"] as? [String: Any])?["udp"] as? [[String: Any]] ?? []
            if let salamander = udpMasks.first(where: { ($0["type"] as? String)?.lowercased() == "salamander" }) {
                obfs = "salamander"
                obfsPassword = ((salamander["settings"] as? [String: Any])?["password"] as? String).nonEmpty
            }
            let hy2 = Hysteria2Settings(auth: auth, tls: tlsOptions(tlsSettings), obfs: obfs, obfsPassword: obfsPassword)
            return ServerConfig(name: name, host: host, port: port, settings: .hysteria2(hy2), isHidden: hidden ? true : nil)

        default:
            throw ImportError.unsupportedScheme(proto)
        }
    }

    private static func tlsOptions(_ dict: [String: Any]) -> TLSOptions {
        TLSOptions(
            serverName: (dict["serverName"] as? String).nonEmpty,
            fingerprint: (dict["fingerprint"] as? String).nonEmpty,
            alpn: stringList(dict["alpn"]),
            allowInsecure: dict["allowInsecure"] as? Bool ?? false,
            pinnedCertSHA256: (dict["pinnedPeerCertSha256"] as? String).nonEmpty
        )
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let array = value as? [String] { return array.filter { !$0.isEmpty } }
        if let string = value as? String { return ShareLinkParser.list(string) }
        return []
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let double as Double: return Int(exactly: double)
        case let string as String: return Int(string)
        default: return nil
        }
    }
}
