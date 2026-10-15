import Foundation

/// Which traffic goes through the VPN.
public enum RoutingMode: String, Codable, CaseIterable, Sendable {
    /// Everything through the VPN.
    case all
    /// Only the selected apps through the VPN, the rest direct.
    case onlySelected
    /// Everything through the VPN except the selected apps.
    case allExceptSelected
}

/// Per-connection secrets for the local mihomo API and proxy port.
/// Generated fresh on every connect, kept only in memory.
public struct CoreSession: Codable, Equatable, Sendable {
    public var controllerPort: Int
    public var controllerSecret: String
    public var mixedPort: Int
    public var mixedUser: String
    public var mixedPassword: String

    public init(controllerPort: Int, controllerSecret: String, mixedPort: Int, mixedUser: String, mixedPassword: String) {
        self.controllerPort = controllerPort
        self.controllerSecret = controllerSecret
        self.mixedPort = mixedPort
        self.mixedUser = mixedUser
        self.mixedPassword = mixedPassword
    }

    /// Random secrets for the given ports.
    public static func random(controllerPort: Int, mixedPort: Int) -> CoreSession {
        CoreSession(
            controllerPort: controllerPort,
            controllerSecret: RandomToken.hex(bytes: 24),
            mixedPort: mixedPort,
            mixedUser: "vfy" + RandomToken.hex(bytes: 4),
            mixedPassword: RandomToken.hex(bytes: 24)
        )
    }

    public var controllerURL: URL {
        URL(string: "http://127.0.0.1:\(controllerPort)")!
    }
}

/// What the app asks the privileged helper to run. The helper builds the
/// mihomo config from this itself: it never takes a raw config or a file path.
public struct CoreStartRequest: Codable, Equatable, Sendable {
    public var servers: [ServerConfig]
    public var groups: [ServerGroup]
    /// Id of the server or group to use.
    public var selectedID: String
    public var routing: RoutingMode
    /// Absolute paths of .app bundles for the per-app rules.
    public var appPaths: [String]
    public var session: CoreSession
    public var ipv6: Bool

    public init(
        servers: [ServerConfig],
        groups: [ServerGroup],
        selectedID: String,
        routing: RoutingMode,
        appPaths: [String],
        session: CoreSession,
        ipv6: Bool = true
    ) {
        self.servers = servers
        self.groups = groups
        self.selectedID = selectedID
        self.routing = routing
        self.appPaths = appPaths
        self.session = session
        self.ipv6 = ipv6
    }
}

public enum RandomToken {
    /// Hex string from the system's secure random generator.
    public static func hex(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in
            let byte = UInt8.random(in: 0...255, using: &generator)
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}
