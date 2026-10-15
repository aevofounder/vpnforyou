import Foundation
import Observation
import VPNCore

/// Which apps go through the VPN. Paths of apps are not secrets: UserDefaults.
@MainActor
@Observable
final class RoutingStore {
    private(set) var mode: RoutingMode
    private(set) var paths: [String]

    private static let modeKey = "routing.mode"
    private static let appsKey = "routing.apps"

    init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Self.modeKey).flatMap(RoutingMode.init(rawValue:)) ?? .all
        paths = defaults.stringArray(forKey: Self.appsKey) ?? []
    }

    func setMode(_ mode: RoutingMode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
    }

    func isSelected(_ path: String) -> Bool {
        paths.contains(path)
    }

    func set(_ path: String, selected: Bool) {
        if selected {
            if !paths.contains(path) { paths.append(path) }
        } else {
            paths.removeAll { $0 == path }
        }
        UserDefaults.standard.set(paths, forKey: Self.appsKey)
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

    /// Turns one app on or off; the running core picks it up without reconnecting.
    static func setApp(_ path: String, selected: Bool, connection: ConnectionManager, routing: RoutingStore) async {
        routing.set(path, selected: selected)
        await connection.updateApps(routing.paths)
    }
}
