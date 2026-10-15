import SwiftUI

@main
struct VPNforYouApp: App {
    @AppStorage(AppearanceKey.theme) private var theme: AppTheme = .system
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("VPNforYou", systemImage: "shield") {
            MenuContentView()
                .environment(model)
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
