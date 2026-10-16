import Foundation

/// A set of servers from one subscription, or keys added by hand.
/// Holds secrets (the subscription URL contains an access token): Keychain only.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        case subscription(url: String)
        case manual
    }

    public var id: UUID
    public var name: String
    public var source: Source
    public var servers: [ServerConfig]
    public var groups: [ServerGroup]
    public var skipped: [SkippedEntry]
    public var usage: SubscriptionUsage?
    public var updatedAt: Date?
    public var updateIntervalHours: Int?
    /// Ids in the subscription's own order; nil for profiles saved before it existed.
    public var order: [String]?

    public init(
        id: UUID = UUID(),
        name: String,
        source: Source,
        servers: [ServerConfig] = [],
        groups: [ServerGroup] = [],
        skipped: [SkippedEntry] = [],
        usage: SubscriptionUsage? = nil,
        updatedAt: Date? = nil,
        updateIntervalHours: Int? = nil,
        order: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.servers = servers
        self.groups = groups
        self.skipped = skipped
        self.usage = usage
        self.updatedAt = updatedAt
        self.updateIntervalHours = updateIntervalHours
        self.order = order
    }

    public var subscriptionURL: String? {
        if case .subscription(let url) = source { return url }
        return nil
    }

    /// Servers shown in the list: hidden members of auto-select groups are left out.
    public var visibleServers: [ServerConfig] {
        servers.filter { $0.isHidden != true }
    }

    public func server(id: String) -> ServerConfig? {
        servers.first { $0.id == id }
    }

    /// One row of the server list: an auto-select group or a server.
    public enum Entry: Identifiable, Equatable, Sendable {
        case group(ServerGroup)
        case server(ServerConfig)

        public var id: String {
            switch self {
            case .group(let group): group.id
            case .server(let server): server.id
            }
        }
    }

    /// Groups and visible servers in the subscription's order (as in Incy);
    /// anything missing from that order follows, groups first.
    public var entries: [Entry] {
        let visible = visibleServers
        let groupByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let serverByID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [Entry] = []
        for id in order ?? [] where !seen.contains(id) {
            if let group = groupByID[id] {
                result.append(.group(group))
                seen.insert(id)
            } else if let server = serverByID[id] {
                result.append(.server(server))
                seen.insert(id)
            }
        }
        for group in groups where seen.insert(group.id).inserted { result.append(.group(group)) }
        for server in visible where seen.insert(server.id).inserted { result.append(.server(server)) }
        return result
    }

    /// Whether a subscription is due for a refresh.
    public func needsRefresh(now: Date = Date(), defaultIntervalHours: Int = 12) -> Bool {
        guard subscriptionURL != nil else { return false }
        guard let updatedAt else { return true }
        let hours = updateIntervalHours ?? defaultIntervalHours
        return now.timeIntervalSince(updatedAt) >= Double(hours) * 3_600
    }

    /// Replaces the servers with a fresh subscription result.
    public mutating func apply(_ fetched: FetchedSubscription, now: Date = Date()) {
        servers = fetched.parsed.servers
        groups = fetched.parsed.groups
        skipped = fetched.parsed.skipped
        usage = fetched.usage
        updatedAt = now
        updateIntervalHours = fetched.updateIntervalHours
        order = fetched.parsed.order
        if let title = fetched.title { name = title }
    }

    /// Adds hand-pasted servers, keeping existing ones.
    public mutating func merge(_ parsed: ParsedSubscription, now: Date = Date()) {
        var combined = ParsedSubscription(servers: servers, groups: groups, order: order)
        combined.merge(parsed)
        servers = combined.servers
        groups = combined.groups
        order = combined.order
        skipped = parsed.skipped
        updatedAt = now
    }
}

/// Saves profiles as one JSON blob in a `SecretStore` (the Keychain in the app).
public struct ProfileStore: Sendable {
    public static let key = "profiles.v1"
    private let secrets: SecretStore

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    public func load() throws -> [Profile] {
        guard let data = try secrets.data(for: Self.key) else { return [] }
        return try JSONDecoder().decode([Profile].self, from: data)
    }

    public func save(_ profiles: [Profile]) throws {
        let data = try JSONEncoder().encode(profiles)
        try secrets.set(data, for: Self.key)
    }
}
