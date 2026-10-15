import Foundation
import Observation
import VPNCore

/// Which apps go through the VPN. Each mode keeps its own list, so switching
/// between "only these" and "all except these" does not mix them up.
/// Paths of apps are not secrets: UserDefaults.
@MainActor
@Observable
final class RoutingStore {
    private(set) var mode: RoutingMode
    private(set) var onlyPaths: [String]
    private(set) var exceptPaths: [String]

    private static let modeKey = "routing.mode"
    private static let onlyKey = "routing.apps.only"
    private static let exceptKey = "routing.apps.except"

    init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Self.modeKey).flatMap(RoutingMode.init(rawValue:)) ?? .all
        onlyPaths = defaults.stringArray(forKey: Self.onlyKey) ?? []
        exceptPaths = defaults.stringArray(forKey: Self.exceptKey) ?? []
    }

    /// The list the core gets for the current mode.
    var paths: [String] {
        switch mode {
        case .all: []
        case .onlySelected: onlyPaths
        case .allExceptSelected: exceptPaths
        }
    }

    func setMode(_ mode: RoutingMode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
    }

    /// Whether the app's traffic goes through the VPN in the current mode.
    func goesThroughVPN(_ path: String) -> Bool {
        switch mode {
        case .all: true
        case .onlySelected: onlyPaths.contains(path)
        case .allExceptSelected: !exceptPaths.contains(path)
        }
    }

    /// Sets the toggle "через VPN" for one app in the current mode.
    func setThroughVPN(_ path: String, _ on: Bool) {
        switch mode {
        case .all:
            return
        case .onlySelected:
            onlyPaths = Self.updated(onlyPaths, path, include: on)
            UserDefaults.standard.set(onlyPaths, forKey: Self.onlyKey)
        case .allExceptSelected:
            exceptPaths = Self.updated(exceptPaths, path, include: !on)
            UserDefaults.standard.set(exceptPaths, forKey: Self.exceptKey)
        }
    }

    /// Every app mentioned in either list, for the apps screen.
    var allListedPaths: [String] {
        var seen = Set<String>()
        return (onlyPaths + exceptPaths).filter { seen.insert($0).inserted }
    }

    private static func updated(_ list: [String], _ path: String, include: Bool) -> [String] {
        var list = list.filter { $0 != path }
        if include { list.append(path) }
        return Array(list.suffix(MihomoConfigBuilder.maxApps))
    }
}

/// Actions that need the model, the connection and the routing together.
@MainActor
enum VPNActions {
    static func connect(model: AppModel, connection: ConnectionManager, routing: RoutingStore) async {
        guard let parts = model.connectionParts() else { return }
        await connection.connect(servers: parts.servers, groups: parts.groups, selectedID: parts.selectedID,
                                 routing: routing.mode, appPaths: routing.paths)
    }

    static func toggle(model: AppModel, connection: ConnectionManager, routing: RoutingStore) async {
        if connection.state.isConnected {
            await connection.disconnect()
        } else {
            await connect(model: model, connection: connection, routing: routing)
        }
    }

    /// Selects a server and, when connected, switches to it right away.
    static func select(_ id: String, model: AppModel, connection: ConnectionManager, routing: RoutingStore) async {
        model.select(id)
        guard connection.state.isConnected, let parts = model.connectionParts() else { return }
        await connection.switchTo(servers: parts.servers, groups: parts.groups, selectedID: parts.selectedID,
                                  routing: routing.mode, appPaths: routing.paths)
    }

    /// Applies a routing mode change: a running core needs new rules, so it reconnects.
    static func setMode(_ mode: RoutingMode, model: AppModel, connection: ConnectionManager, routing: RoutingStore) async {
        guard mode != routing.mode else { return }
        routing.setMode(mode)
        guard connection.state.isConnected else { return }
        await connection.disconnect()
        await connect(model: model, connection: connection, routing: routing)
    }

    /// Turns one app's "через VPN" toggle; the running core picks it up without reconnecting.
    static func setApp(_ path: String, throughVPN: Bool, connection: ConnectionManager, routing: RoutingStore) async {
        routing.setThroughVPN(path, throughVPN)
        await connection.updateApps(routing.paths)
    }
}
