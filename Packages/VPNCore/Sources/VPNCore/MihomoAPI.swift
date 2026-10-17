import Foundation

/// One call to the mihomo REST API. Only the helper sends these, over the
/// core's root-only Unix socket; the list below is everything it ever asks.
public struct MihomoRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var body: Data?

    public init(method: String = "GET", path: String, body: Data? = nil) {
        self.method = method
        self.path = path
        self.body = body
    }

    public static let version = MihomoRequest(path: "/version")
    public static let connections = MihomoRequest(path: "/connections")

    /// Picks the server or group in the main selector without reconnecting.
    public static func select(_ name: String) -> MihomoRequest {
        let body = try? JSONSerialization.data(withJSONObject: ["name": name])
        return MihomoRequest(method: "PUT", path: "/proxies/\(MihomoConfigBuilder.proxyGroup)", body: body)
    }

    /// Latency through one proxy (server id or group id).
    public static func delay(_ name: String, timeoutMilliseconds: Int = 5_000) -> MihomoRequest {
        let url = pathComponent(MihomoConfigBuilder.testURL)
        return MihomoRequest(path: "/proxies/\(pathComponent(name))/delay?url=\(url)&timeout=\(timeoutMilliseconds)")
    }

    /// Re-reads the per-app rules file right away.
    public static let reloadApps = MihomoRequest(method: "PUT", path: "/providers/rules/\(MihomoConfigBuilder.appsProvider)")

    static func pathComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? text
    }
}

/// Upload and download totals of the running core, from `/connections`.
public struct TrafficTotals: Codable, Equatable, Sendable {
    public var upload: Int64
    public var download: Int64

    public init(upload: Int64, download: Int64) {
        self.upload = upload
        self.download = download
    }

    /// Bytes per second between two readings.
    public static func rate(from previous: TrafficTotals, to current: TrafficTotals, seconds: TimeInterval) -> TrafficSample {
        let interval = max(seconds, 0.1)
        return TrafficSample(
            up: Int64(Double(max(0, current.upload - previous.upload)) / interval),
            down: Int64(Double(max(0, current.download - previous.download)) / interval)
        )
    }
}

/// One line of `/traffic`: bytes per second.
/// Bytes per second up and down, one point of the traffic graph.
public struct TrafficSample: Codable, Equatable, Sendable {
    public var up: Int64
    public var down: Int64

    public init(up: Int64, down: Int64) {
        self.up = up
        self.down = down
    }
}

public struct DelayResult: Codable, Equatable, Sendable {
    public var delay: Int?
    public var message: String?
}

/// `/connections` snapshot.
public struct ConnectionsSnapshot: Codable, Equatable, Sendable {
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

    public struct Connection: Codable, Equatable, Sendable, Identifiable {
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

    public struct Metadata: Codable, Equatable, Sendable {
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
        public var appPath: String?
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
                appPath: connection.appBundlePath,
                destination: connection.destination,
                isDirect: connection.isDirect,
                downPerSecond: Int64(Double(down) / seconds),
                upPerSecond: Int64(Double(up) / seconds)
            )
        }
        .sorted { ($0.downPerSecond + $0.upPerSecond, $0.appName) > ($1.downPerSecond + $1.upPerSecond, $1.appName) }
    }
}
