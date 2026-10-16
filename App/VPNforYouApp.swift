import SwiftUI

@main
struct VPNforYouApp: App {
    @AppStorage(AppearanceKey.theme) private var theme: AppTheme = .system
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var connection: ConnectionManager
    @State private var routing: RoutingStore
    @State private var diagnostics: Diagnostics
    @State private var installed = InstalledApps()

    static let autoConnectKey = "general.autoConnect"

    init() {
        let model = AppModel()
        let connection = ConnectionManager()
        let routing = RoutingStore()
        let diagnostics = Diagnostics()
        connection.onStateChange = { [weak connection, weak diagnostics] _ in
            guard let connection, let diagnostics else { return }
            diagnostics.connectionChanged(connection: connection)
        }
        GlobalHotKey.shared.action = { [weak model, weak connection, weak routing] in
            guard let model, let connection, let routing, !connection.state.isBusy else { return }
            Task { await VPNActions.toggle(model: model, connection: connection, routing: routing) }
        }
        GlobalHotKey.shared.apply()
        Updater.shared.isVPNConnected = { [weak connection] in connection?.state.isConnected ?? false }
        Updater.shared.start()
        let reconnect = Updater.takeReconnectFlag()
        if reconnect || UserDefaults.standard.bool(forKey: Self.autoConnectKey) {
            Task {
                // Give the helper check in ConnectionManager.init a moment first.
                try? await Task.sleep(for: .seconds(2))
                guard connection.state == .disconnected else { return }
                AppLog.add(reconnect ? "Переподключение после обновления" : "Автоподключение при запуске")
                await VPNActions.connect(model: model, connection: connection, routing: routing)
            }
        }
        _model = State(initialValue: model)
        _connection = State(initialValue: connection)
        _routing = State(initialValue: routing)
        _diagnostics = State(initialValue: diagnostics)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
                .environment(connection)
                .environment(routing)
                .environment(diagnostics)
                .environment(installed)
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        } label: {
            MenuBarLabel(model: model, connection: connection)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(connection)
                .environment(routing)
                .environment(diagnostics)
                .environment(installed)
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
