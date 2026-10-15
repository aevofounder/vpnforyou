import AppKit
import Observation
import SwiftUI
import VPNCore

/// Polls the core's `/connections` once a second while the Activity window is open.
@MainActor
@Observable
final class ActivityMonitor {
    private(set) var apps: [AppActivity] = []
    private(set) var connectionCount = 0
    private(set) var isPaused = false
    private(set) var error: String?
    @ObservationIgnored private var previous: ConnectionsSnapshot?
    @ObservationIgnored private var previousDate: Date?
    @ObservationIgnored private var frozen = false

    #if DEBUG
    /// Screenshot fixtures (Debug builds only): fixed rows, no polling.
    func previewSet(apps: [AppActivity], connections: Int) {
        self.apps = apps
        connectionCount = connections
        frozen = true
    }
    #endif

    func run(connection: ConnectionManager) async {
        guard !frozen else { return }
        previous = nil
        while !Task.isCancelled {
            if !isPaused { await poll(connection: connection) }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused { previous = nil }
    }

    private func poll(connection: ConnectionManager) async {
        guard connection.state.isConnected else {
            apps = []
            connectionCount = 0
            previous = nil
            return
        }
        do {
            let snapshot = try await connection.connections()
            let now = Date()
            let interval = previousDate.map { now.timeIntervalSince($0) } ?? 1
            let rows = ConnectionRates.rows(previous: previous, current: snapshot, interval: interval)
            apps = ActivitySummary.byApp(rows)
            connectionCount = snapshot.connections.count
            previous = snapshot
            previousDate = now
            error = nil
        } catch {
            self.error = "Ядро не ответило"
        }
    }
}

/// Activity window: which programs use the network right now, through the VPN or directly.
struct ActivityView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    @Environment(InstalledApps.self) private var installed
    @State private var monitor: ActivityMonitor

    @MainActor
    init(monitor: ActivityMonitor? = nil) {
        _monitor = State(initialValue: monitor ?? ActivityMonitor())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !connection.state.isConnected {
                placeholder(icon: "shield.slash", text: "VPN выключен. Активность видна, пока VPN подключён.")
            } else if monitor.apps.isEmpty {
                placeholder(icon: "dot.radiowaves.left.and.right", text: monitor.error ?? "Пока нет соединений")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(monitor.apps) { app in
                            ActivityRow(app: app)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .task(id: connection.state.isConnected) { await monitor.run(connection: connection) }
        .onAppear { installed.loadIfNeeded(listed: routing.allListedPaths) }
    }

    private var viaVPN: Int { monitor.apps.filter { $0.viaVPN > 0 }.count }
    private var directOnly: Int { monitor.apps.filter { $0.viaVPN == 0 }.count }

    private var header: some View {
        HStack(spacing: 16) {
            Summary(value: viaVPN, label: Format.word(viaVPN, "программа", "программы", "программ") + " через VPN",
                    highlighted: true)
            Summary(value: directOnly, label: "напрямую", highlighted: false)
            Summary(value: monitor.connectionCount,
                    label: Format.word(monitor.connectionCount, "соединение", "соединения", "соединений"),
                    highlighted: false)
            Spacer()
            Button {
                monitor.togglePause()
            } label: {
                Label(monitor.isPaused ? "Продолжить" : "Пауза",
                      systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
            }
            .glassButtonStyle()
            .disabled(!connection.state.isConnected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Palette.ink3)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct Summary: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let value: Int
    let label: String
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(value)")
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(highlighted ? accent.color : Palette.ink)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityRow: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    @Environment(InstalledApps.self) private var installed
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let app: AppActivity

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    RouteBadge(app: app)
                }
                Text(app.destinations.prefix(2).joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("↓ " + Format.rate(app.downPerSecond))
                Text("↑ " + Format.rate(app.upPerSecond))
                    .foregroundStyle(Palette.ink3)
            }
            .font(.system(size: 11).monospacedDigit())
            .frame(width: 92, alignment: .trailing)
            if let path = app.path, routing.mode != .all {
                Toggle("Через VPN", isOn: Binding(
                    get: { routing.goesThroughVPN(path) },
                    set: { on in
                        Task { await VPNActions.setApp(path, throughVPN: on, connection: connection, routing: routing) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Пускать \(app.name) через VPN")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .background(Palette.surface, in: shape)
        .overlay(shape.strokeBorder(Palette.line))
        .help(app.path ?? app.name)
    }

    @ViewBuilder
    private var icon: some View {
        if let path = app.path {
            Image(nsImage: installed.icon(for: path))
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "gearshape.2")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink3)
                .frame(width: 26, height: 26)
                .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct RouteBadge: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let app: AppActivity

    var body: some View {
        let (text, color): (String, Color) = app.isMixed
            ? ("частично", Palette.warn)
            : (app.viaVPN > 0 ? ("VPN", accent.color) : ("напрямую", Palette.ink3))
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(color.opacity(0.12), in: Capsule())
    }
}
