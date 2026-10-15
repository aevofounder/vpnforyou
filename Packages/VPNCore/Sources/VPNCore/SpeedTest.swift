import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Speed test against speed.cloudflare.com: latency, download, upload.
public enum SpeedTest {
    public static let host = "speed.cloudflare.com"

    /// Bytes requested for the download phase; the phase also stops after `phaseSeconds`.
    public static let downloadBytes = 25_000_000
    /// Bytes sent in the upload phase.
    public static let uploadBytes = 10_000_000
    public static let phaseSeconds: TimeInterval = 8
    public static let latencySamples = 5

    /// The most traffic one test can use, for the "≈ 35 МБ" note.
    public static var maxTrafficBytes: Int64 { Int64(downloadBytes + uploadBytes) }

    public static func downloadURL(bytes: Int) -> URL {
        URL(string: "https://\(host)/__down?bytes=\(max(0, bytes))")!
    }

    public static var uploadURL: URL {
        URL(string: "https://\(host)/__up")!
    }

    public static func latencyRequest() -> URLRequest {
        URLRequest(url: downloadURL(bytes: 0), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
    }

    public static func downloadRequest() -> URLRequest {
        URLRequest(url: downloadURL(bytes: downloadBytes), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                   timeoutInterval: 15)
    }

    public static func uploadRequest() -> URLRequest {
        var request = URLRequest(url: uploadURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Megabits per second; 0 for empty or instant samples.
    public static func megabitsPerSecond(bytes: Int64, seconds: TimeInterval) -> Double {
        guard bytes > 0, seconds > 0.05 else { return 0 }
        return Double(bytes) * 8 / seconds / 1_000_000
    }

    /// Median of latency samples in milliseconds, nil when there are none.
    public static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// Which way the test traffic goes.
public enum SpeedRoute: String, CaseIterable, Codable, Identifiable, Sendable {
    case vpn, direct

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vpn: "Через VPN"
        case .direct: "Напрямую"
        }
    }
}

public struct SpeedResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var route: SpeedRoute
    public var date: Date
    /// Name of the server for VPN tests; nil for direct ones.
    public var serverName: String?
    public var latencyMs: Double?
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    public var bytesUsed: Int64

    public init(id: UUID = UUID(), route: SpeedRoute, date: Date = Date(), serverName: String? = nil,
                latencyMs: Double? = nil, downloadMbps: Double? = nil, uploadMbps: Double? = nil, bytesUsed: Int64 = 0) {
        self.id = id
        self.route = route
        self.date = date
        self.serverName = serverName
        self.latencyMs = latencyMs
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.bytesUsed = bytesUsed
    }
}

/// Server latency: from the core's URL test when connected, a TCP connect otherwise.
public enum PingQuality: Equatable, Sendable {
    case good, fair, poor

    public init(milliseconds: Int) {
        switch milliseconds {
        case ..<120: self = .good
        case ..<300: self = .fair
        default: self = .poor
        }
    }
}

public enum PingSort {
    /// Ids ordered by ping, unmeasured ones last in their original order.
    public static func byPing(_ ids: [String], pings: [String: Int]) -> [String] {
        ids.enumerated().sorted { lhs, rhs in
            switch (pings[lhs.element], pings[rhs.element]) {
            case let (left?, right?): left == right ? lhs.offset < rhs.offset : left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// The fastest id among the measured ones.
    public static func fastest(_ ids: [String], pings: [String: Int]) -> String? {
        byPing(ids, pings: pings).first { pings[$0] != nil }
    }
}
