import Foundation

/// Proxy protocols the app can import. Others are reported as skipped.
public enum ProxyProtocol: String, Codable, Sendable {
    case vless
    case hysteria2
}

/// VLESS transport ("type" in share links, "network" in Xray JSON).
public enum Transport: String, Codable, Sendable, CaseIterable {
    case tcp, ws, grpc, xhttp, httpupgrade

    public var title: String {
        switch self {
        case .tcp: "TCP"
        case .ws: "WS"
        case .grpc: "gRPC"
        case .xhttp: "XHTTP"
        case .httpupgrade: "HTTPUpgrade"
        }
    }
}

public enum TransportSecurity: String, Codable, Sendable {
    case none, tls, reality
}

public struct TLSOptions: Codable, Equatable, Sendable {
    public var serverName: String?
    public var fingerprint: String?
    public var alpn: [String]
    public var allowInsecure: Bool
    public var pinnedCertSHA256: String?

    public init(
        serverName: String? = nil,
        fingerprint: String? = nil,
        alpn: [String] = [],
        allowInsecure: Bool = false,
        pinnedCertSHA256: String? = nil
    ) {
        self.serverName = serverName
        self.fingerprint = fingerprint
        self.alpn = alpn
        self.allowInsecure = allowInsecure
        self.pinnedCertSHA256 = pinnedCertSHA256
    }
}

public struct RealityOptions: Codable, Equatable, Sendable {
    public var publicKey: String
    public var shortID: String?
    public var spiderX: String?

    public init(publicKey: String, shortID: String? = nil, spiderX: String? = nil) {
        self.publicKey = publicKey
        self.shortID = shortID
        self.spiderX = spiderX
    }
}

public struct VLESSSettings: Codable, Equatable, Sendable {
    public var uuid: String
    public var flow: String?
    public var encryption: String?
    public var transport: Transport
    public var security: TransportSecurity
    public var tls: TLSOptions
    public var reality: RealityOptions?
    /// Path for WS, XHTTP and HTTPUpgrade.
    public var path: String?
    /// Host header for WS, XHTTP and HTTPUpgrade.
    public var host: String?
    /// gRPC service name.
    public var serviceName: String?
    /// XHTTP mode: auto, packet-up, stream-up, stream-one.
    public var xhttpMode: String?

    public init(
        uuid: String,
        flow: String? = nil,
        encryption: String? = nil,
        transport: Transport = .tcp,
        security: TransportSecurity = .none,
        tls: TLSOptions = TLSOptions(),
        reality: RealityOptions? = nil,
        path: String? = nil,
        host: String? = nil,
        serviceName: String? = nil,
        xhttpMode: String? = nil
    ) {
        self.uuid = uuid
        self.flow = flow
        self.encryption = encryption
        self.transport = transport
        self.security = security
        self.tls = tls
        self.reality = reality
        self.path = path
        self.host = host
        self.serviceName = serviceName
        self.xhttpMode = xhttpMode
    }
}

public struct Hysteria2Settings: Codable, Equatable, Sendable {
    public var auth: String
    public var tls: TLSOptions
    /// Obfuscation type, normally "salamander".
    public var obfs: String?
    public var obfsPassword: String?
    /// Port hopping range such as "20000-30000" or "443,5000-6000".
    public var portHopping: String?

    public init(
        auth: String,
        tls: TLSOptions = TLSOptions(),
        obfs: String? = nil,
        obfsPassword: String? = nil,
        portHopping: String? = nil
    ) {
        self.auth = auth
        self.tls = tls
        self.obfs = obfs
        self.obfsPassword = obfsPassword
        self.portHopping = portHopping
    }
}

public enum ProxySettings: Codable, Equatable, Sendable {
    case vless(VLESSSettings)
    case hysteria2(Hysteria2Settings)
}

/// One server from a share link or a subscription.
/// Contains secrets (UUID, passwords): store it only in the Keychain and never log it.
public struct ServerConfig: Codable, Equatable, Identifiable, Sendable {
    /// Stable id derived from the connection settings (not the name),
    /// so the selection survives a subscription refresh.
    public var id: String
    public var name: String
    public var countryCode: String?
    public var host: String
    public var port: Int
    public var settings: ProxySettings
    /// True for servers that only exist inside an auto-select group.
    public var isHidden: Bool?

    public init(
        name: String,
        host: String,
        port: Int,
        settings: ProxySettings,
        countryCode: String? = nil,
        isHidden: Bool? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.settings = settings
        self.countryCode = countryCode ?? CountryDetector.detect(in: name)
        self.isHidden = isHidden
        self.id = StableID.server(host: host, port: port, settings: settings)
    }

    public var proxyProtocol: ProxyProtocol {
        switch settings {
        case .vless: .vless
        case .hysteria2: .hysteria2
        }
    }

    /// Short description without secrets, e.g. "VLESS · XHTTP · Reality".
    public var summary: String {
        switch settings {
        case .vless(let vless):
            var parts = ["VLESS"]
            if vless.transport != .tcp { parts.append(vless.transport.title) }
            switch vless.security {
            case .reality: parts.append("Reality")
            case .tls: parts.append("TLS")
            case .none: break
            }
            return parts.joined(separator: " · ")
        case .hysteria2:
            return "Hysteria2"
        }
    }

    /// Name without flag emoji, for display next to the country code.
    public var displayName: String {
        let stripped = CountryDetector.stripFlags(name)
        return stripped.isEmpty ? name : stripped
    }
}

/// Servers that the provider bundles into one auto-select entry ("Автовыбор").
public struct ServerGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var memberIDs: [String]
    public var countryCode: String?

    public init(name: String, memberIDs: [String]) {
        self.name = name
        self.memberIDs = memberIDs
        self.countryCode = CountryDetector.detect(in: name)
        self.id = StableID.group(name: name, memberIDs: memberIDs)
    }

    public var displayName: String {
        let stripped = CountryDetector.stripFlags(name)
        return stripped.isEmpty ? name : stripped
    }
}

/// An entry that could not be imported. Holds no secrets: only a name and a reason.
public struct SkippedEntry: Codable, Equatable, Sendable {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// Result of parsing links or a subscription body.
public struct ParsedSubscription: Codable, Equatable, Sendable {
    public var servers: [ServerConfig]
    public var groups: [ServerGroup]
    public var skipped: [SkippedEntry]

    public init(servers: [ServerConfig] = [], groups: [ServerGroup] = [], skipped: [SkippedEntry] = []) {
        self.servers = servers
        self.groups = groups
        self.skipped = skipped
    }

    public var isEmpty: Bool { servers.isEmpty && groups.isEmpty }

    /// Adds a server unless an identical one is already present; returns its id.
    @discardableResult
    public mutating func add(_ server: ServerConfig) -> String {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            // A server listed on its own wins over a hidden group member.
            if servers[index].isHidden == true, server.isHidden != true {
                servers[index] = server
            }
            return server.id
        }
        servers.append(server)
        return server.id
    }

    public mutating func merge(_ other: ParsedSubscription) {
        for server in other.servers { add(server) }
        for group in other.groups where !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
        }
        skipped.append(contentsOf: other.skipped)
    }
}

enum StableID {
    static func server(host: String, port: Int, settings: ProxySettings) -> String {
        struct Key: Encodable {
            let host: String
            let port: Int
            let settings: ProxySettings
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Key(host: host.lowercased(), port: port, settings: settings))) ?? Data()
        return "s-" + fnv1a64(data)
    }

    static func group(name: String, memberIDs: [String]) -> String {
        "g-" + fnv1a64(Data((name + "|" + memberIDs.joined(separator: ",")).utf8))
    }

    static func fnv1a64(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
