import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Requests and responses of the mihomo REST API (external-controller).
/// The HTTP itself lives in the app; this part is testable on Linux.
public struct MihomoAPI: Sendable {
    public let session: CoreSession

    public init(session: CoreSession) {
        self.session = session
    }

    public func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: session.controllerURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(session.controllerSecret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public var version: URLRequest { request("/version") }
    public var traffic: URLRequest { request("/traffic") }
    public var connections: URLRequest { request("/connections") }

    /// Picks the server or group in the main selector without reconnecting.
    public func select(_ name: String) -> URLRequest {
        let body = try? JSONSerialization.data(withJSONObject: ["name": name])
        return request("/proxies/\(MihomoConfigBuilder.proxyGroup)", method: "PUT", body: body)
    }

    /// Latency through one proxy (server id or group id).
    public func delay(_ name: String, timeoutMilliseconds: Int = 5_000) -> URLRequest {
        var request = request(
            "/proxies/\(Self.pathComponent(name))/delay",
            query: [
                URLQueryItem(name: "url", value: MihomoConfigBuilder.testURL),
                URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
            ]
        )
        request.timeoutInterval = Double(timeoutMilliseconds) / 1_000 + 2
        return request
    }

    /// Re-reads the per-app rules file right away.
    public var reloadApps: URLRequest {
        request("/providers/rules/\(MihomoConfigBuilder.appsProvider)", method: "PUT")
    }

    static func pathComponent(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? name
    }
}

/// One line of `/traffic`: bytes per second.
public struct TrafficSample: Codable, Equatable, Sendable {
    public var up: Int64
    public var down: Int64
    public var upTotal: Int64?
    public var downTotal: Int64?

    public init(up: Int64, down: Int64, upTotal: Int64? = nil, downTotal: Int64? = nil) {
        self.up = up
        self.down = down
        self.upTotal = upTotal
        self.downTotal = downTotal
    }

    public static func parse(line: String) -> TrafficSample? {
        try? JSONDecoder().decode(TrafficSample.self, from: Data(line.utf8))
    }
}

public struct DelayResult: Codable, Equatable, Sendable {
    public var delay: Int?
    public var message: String?
}

/// `/connections` snapshot.
public struct ConnectionsSnapshot: Decodable, Equatable, Sendable {
    public var downloadTotal: Int64
    public var uploadTotal: Int64
    public var connections: [Connection]

    enum CodingKeys: String, CodingKey {
        case downloadTotal, uploadTotal, connections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadTotal = try container.decodeIfPresent(Int64.self, forKey: .downloadTotal) ?? 0
        uploadTotal = try container.decodeIfPresent(Int64.self, forKey: .uploadTotal) ?? 0
        // mihomo sends null when there are no connections.
        connections = try container.decodeIfPresent([Connection].self, forKey: .connections) ?? []
    }

    public init(downloadTotal: Int64, uploadTotal: Int64, connections: [Connection]) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
    }

    public struct Connection: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var metadata: Metadata
        public var upload: Int64
        public var download: Int64
        public var chains: [String]
        public var rule: String?

        public init(id: String, metadata: Metadata, upload: Int64, download: Int64, chains: [String], rule: String? = nil) {
            self.id = id
            self.metadata = metadata
            self.upload = upload
            self.download = download
            self.chains = chains
            self.rule = rule
        }

        /// DIRECT anywhere in the chain means the connection bypasses the VPN.
        public var isDirect: Bool { chains.contains("DIRECT") || chains.isEmpty }

        /// Where it goes: the domain if known, else the IP.
        public var destination: String {
            if let host = metadata.host, !host.isEmpty { return host }
            if let sniff = metadata.sniffHost, !sniff.isEmpty { return sniff }
            return metadata.destinationIP ?? "—"
        }

        /// The program's name: the .app bundle for apps, else the process name.
        public var appName: String {
            if let path = metadata.processPath, let range = path.range(of: ".app/") {
                let bundle = path[..<range.lowerBound]
                return String(bundle.split(separator: "/").last ?? Substring(bundle))
            }
            if let process = metadata.process, !process.isEmpty { return process }
            return "Система"
        }

        /// Path of the .app bundle, if the process lives inside one.
        public var appBundlePath: String? {
            guard let path = metadata.processPath, let range = path.range(of: ".app/") else { return nil }
            return String(path[..<range.lowerBound]) + ".app"
        }
    }

    public struct Metadata: Decodable, Equatable, Sendable {
        public var network: String?
        public var host: String?
        public var sniffHost: String?
        public var destinationIP: String?
        public var destinationPort: String?
        public var process: String?
        public var processPath: String?

        public init(network: String? = nil, host: String? = nil, sniffHost: String? = nil, destinationIP: String? = nil,
                    destinationPort: String? = nil, process: String? = nil, processPath: String? = nil) {
            self.network = network
            self.host = host
            self.sniffHost = sniffHost
            self.destinationIP = destinationIP
            self.destinationPort = destinationPort
            self.process = process
            self.processPath = processPath
        }
    }

    public static func parse(_ data: Data) throws -> ConnectionsSnapshot {
        try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
    }
}

/// Per-connection speed from two consecutive snapshots.
public enum ConnectionRates {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var appName: String
        public var destination: String
        public var isDirect: Bool
        public var downPerSecond: Int64
        public var upPerSecond: Int64
    }

    public static func rows(previous: ConnectionsSnapshot?, current: ConnectionsSnapshot, interval: TimeInterval) -> [Row] {
        let seconds = max(interval, 0.1)
        let before = Dictionary((previous?.connections ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.connections.map { connection in
            let old = before[connection.id]
            let down = max(0, connection.download - (old?.download ?? connection.download))
            let up = max(0, connection.upload - (old?.upload ?? connection.upload))
            return Row(
                id: connection.id,
                appName: connection.appName,
                destination: connection.destination,
                isDirect: connection.isDirect,
                downPerSecond: Int64(Double(down) / seconds),
                upPerSecond: Int64(Double(up) / seconds)
            )
        }
        .sorted { ($0.downPerSecond + $0.upPerSecond, $0.appName) > ($1.downPerSecond + $1.upPerSecond, $1.appName) }
    }
}
