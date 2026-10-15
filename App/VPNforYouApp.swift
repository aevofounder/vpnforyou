import SwiftUI

@main
struct VPNforYouApp: App {
    @AppStorage(AppearanceKey.theme) private var theme: AppTheme = .system
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var connection: ConnectionManager
    @State private var routing = RoutingStore()
    @State private var diagnostics: Diagnostics

    init() {
        let connection = ConnectionManager()
        let diagnostics = Diagnostics()
        connection.onStateChange = { [weak connection, weak diagnostics] _ in
            guard let connection, let diagnostics else { return }
            diagnostics.connectionChanged(connection: connection)
        }
        _connection = State(initialValue: connection)
        _diagnostics = State(initialValue: diagnostics)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
                .environment(connection)
                .environment(routing)
                .environment(diagnostics)
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        } label: {
            Image(systemName: connection.state.isConnected ? "checkmark.shield.fill" : "shield")
                .accessibilityLabel(connection.state.isConnected ? "VPNforYou: VPN включён" : "VPNforYou: VPN выключен")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(connection)
                .environment(routing)
                .environment(diagnostics)
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
