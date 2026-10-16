import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

/// Plain HTTPS GET in an ephemeral session: no cookies, no cache on disk.
public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: ImportError.network(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: ImportError.network("нет ответа"))
                    return
                }
                var lowered: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let key = key as? String, let value = value as? String { lowered[key.lowercased()] = value }
                }
                continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: lowered, body: data ?? Data()))
            }
            task.resume()
        }
    }
}

public struct FetchedSubscription: Equatable, Sendable {
    public var parsed: ParsedSubscription
    public var usage: SubscriptionUsage?
    public var title: String?
    public var updateIntervalHours: Int?

    public init(parsed: ParsedSubscription, usage: SubscriptionUsage? = nil, title: String? = nil, updateIntervalHours: Int? = nil) {
        self.parsed = parsed
        self.usage = usage
        self.title = title
        self.updateIntervalHours = updateIntervalHours
    }
}

public struct SubscriptionFetcher: Sendable {
    /// Panels (Remnawave, Marzban…) pick the response format by User-Agent.
    /// Clients like Happ and Incy get Xray JSON: every entry keeps the
    /// seller's name ("Автовыбор", "Германия | WebSocket"), balancers become
    /// groups. v2rayN gets a plain list of links, where names are often
    /// internal tags like "[AUTO] nl-1". Ask as a JSON client first and fall
    /// back to the link list if that answer is unusable.
    public static let jsonUserAgent = "Happ/3.10.0"
    public static let linksUserAgent = "v2rayN/7.13"
    public static let defaultUserAgents = [jsonUserAgent, linksUserAgent]
    public static let maxBodySize = 5 * 1024 * 1024

    private let client: HTTPClient
    private let userAgents: [String]

    public init(client: HTTPClient = URLSessionHTTPClient(), userAgents: [String] = SubscriptionFetcher.defaultUserAgents) {
        self.client = client
        self.userAgents = userAgents.isEmpty ? Self.defaultUserAgents : userAgents
    }

    public func fetch(_ urlString: String) async throws -> FetchedSubscription {
        guard let url = SubscriptionURL.validate(urlString) else { throw ImportError.invalidSubscriptionURL }
        var lastError: Error = ImportError.emptySubscription
        for userAgent in userAgents {
            do {
                return try await fetch(url, userAgent: userAgent)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetch(_ url: URL, userAgent: String) async throws -> FetchedSubscription {
        let response = try await client.get(url, headers: ["User-Agent": userAgent, "Accept": "*/*"])
        guard (200..<300).contains(response.status) else { throw ImportError.httpStatus(response.status) }
        guard response.body.count <= Self.maxBodySize else { throw ImportError.tooLarge }

        let parsed = try SubscriptionDecoder.decode(response.body)
        guard !parsed.isEmpty else {
            if let first = parsed.skipped.first { throw ImportError.nothingImported(first.reason) }
            throw ImportError.emptySubscription
        }
        return FetchedSubscription(
            parsed: parsed,
            usage: response.headers["subscription-userinfo"].flatMap(SubscriptionUsage.init(header:)),
            title: SubscriptionHeaders.title(response.headers["profile-title"]),
            updateIntervalHours: SubscriptionHeaders.updateIntervalHours(response.headers["profile-update-interval"])
        )
    }
}

public enum SubscriptionURL {
    /// http(s) URL with a host, or nil.
    public static func validate(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Plain http leaks the subscription token to anyone on the network.
    public static func isInsecure(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    /// Host only, safe to show: the path usually holds the access token.
    public static func displayHost(_ text: String) -> String? {
        validate(text)?.host
    }
}
