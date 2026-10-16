import SwiftUI
import VPNCore

/// The menu bar icon in the style picked in the settings.
struct MenuBarLabel: View {
    @AppStorage(AppearanceKey.menuIcon) private var style: MenuIconStyle = .shield
    let model: AppModel
    let connection: ConnectionManager

    var body: some View {
        let connected = connection.state.isConnected
        Group {
            switch style {
            case .shield:
                Image(systemName: connected ? "checkmark.shield.fill" : busy ? "shield.lefthalf.filled" : "shield")
            case .dot:
                Image(systemName: connected ? "circle.fill" : busy ? "circle.dotted" : "circle")
            case .country:
                if connected, let code = connection.connectedID.flatMap({ model.label(for: $0)?.code }) {
                    Text(code)
                } else {
                    Image(systemName: connected ? "checkmark.shield.fill" : "shield")
                }
            case .speed:
                if connected {
                    Text("↓" + Self.compact(connection.latestTraffic?.down ?? 0))
                        .monospacedDigit()
                } else {
                    Image(systemName: "shield")
                }
            }
        }
        .accessibilityLabel(connected ? "VPNforYou: VPN включён" : "VPNforYou: VPN выключен")
    }

    private var busy: Bool { connection.state.isBusy }

    /// "2.4M", "380K", "0K": fits the menu bar.
    static func compact(_ bytesPerSecond: Int64) -> String {
        let value = Double(max(0, bytesPerSecond))
        if value >= 1_000_000 { return String(format: value >= 10_000_000 ? "%.0fM" : "%.1fM", value / 1_000_000) }
        return String(format: "%.0fK", value / 1_000)
    }
}
