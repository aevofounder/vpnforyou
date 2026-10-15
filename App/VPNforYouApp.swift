import SwiftUI

@main
struct VPNforYouApp: App {
    @AppStorage(AppearanceKey.theme) private var theme: AppTheme = .system
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var connection = ConnectionManager()
    @State private var routing = RoutingStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
                .environment(connection)
                .environment(routing)
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
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
