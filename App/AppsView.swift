import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VPNCore

/// Programs screen: routing mode and a "через VPN" toggle per program.
/// Toggles apply to a running VPN at once, without reconnecting.
struct AppsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    @Environment(InstalledApps.self) private var installed
    @State private var query = ""
    @State private var addError: String?

    var body: some View {
        VStack(spacing: 8) {
            ScreenHeader("Программы") {
                Button {
                    addApp()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .glassButtonStyle()
                .buttonBorderShape(.circle)
                .help("Добавить программу, которой нет в списке")
                .accessibilityLabel("Добавить программу")
            }

            Card {
                VStack(spacing: 2) {
                    ModeRow(mode: .all, title: "Весь трафик через VPN", subtitle: "Ползунки не нужны")
                    ModeRow(mode: .onlySelected, title: "Только выбранные программы",
                            subtitle: "Остальные ходят напрямую")
                    ModeRow(mode: .allExceptSelected, title: "Все, кроме выбранных",
                            subtitle: "Выключенные ходят напрямую")
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Palette.ink3)
                        TextField("Поиск программы", text: $query)
                            .textFieldStyle(.plain)
                        if installed.isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Palette.surface2.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if routing.mode == .all {
                        Text("Сейчас через VPN идёт всё. Выберите режим выше, чтобы включать программы ползунками.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if routing.mode == .onlySelected, routing.paths.isEmpty {
                        Label("Ни одна программа не включена: через VPN сейчас ничего не идёт.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(visibleApps) { app in
                                AppToggleRow(app: app)
                            }
                            if visibleApps.isEmpty, !installed.isLoading {
                                Text(query.isEmpty ? "Программы не найдены" : "Ничего не найдено")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.ink3)
                                    .padding(.vertical, 12)
                            }
                        }
                    }
                    .frame(height: 260)

                    if let addError {
                        Text(addError)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.warn)
                    }
                    Text("Safari, Почта и App Store ходят в сеть через системные процессы macOS, поэтому для них выбор работает неточно.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { installed.loadIfNeeded(listed: routing.allListedPaths) }
    }

    /// Programs routed through the VPN first (in "only" mode) or the excluded
    /// ones first (in "except" mode), then the rest by name.
    private var visibleApps: [AppEntry] {
        let filtered = query.isEmpty
            ? installed.apps
            : installed.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        guard routing.mode != .all else { return filtered }
        let chosen = Set(routing.paths)
        return filtered.filter { chosen.contains($0.path) } + filtered.filter { !chosen.contains($0.path) }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Выберите программу"
        panel.prompt = "Добавить"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let entry = installed.add(url: url) {
            addError = nil
            query = entry.name
            // A program added by hand is meant to be chosen: through the VPN in
            // "only" mode, around it in "except" mode.
            if routing.mode != .all {
                let throughVPN = routing.mode == .onlySelected
                Task { await VPNActions.setApp(entry.path, throughVPN: throughVPN, connection: connection, routing: routing) }
            }
        } else {
            addError = "Это не программа macOS (.app)"
        }
    }
}

private struct ModeRow: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    let mode: RoutingMode
    let title: String
    let subtitle: String

    var body: some View {
        let selected = routing.mode == mode
        Button {
            Task { await VPNActions.setMode(mode, model: model, connection: connection, routing: routing) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Palette.ink3))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connection.state.isBusy)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppToggleRow: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    @Environment(InstalledApps.self) private var installed
    let app: AppEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: installed.icon(for: app.path))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if app.usesSystemNetworking {
                    Text("работает неточно")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.warn)
                }
            }
            Spacer(minLength: 6)
            Toggle("Через VPN", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(routing.mode == .all)
                .accessibilityLabel("\(app.name) через VPN")
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 34)
        .help(app.path)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { routing.goesThroughVPN(app.path) },
            set: { on in
                Task { await VPNActions.setApp(app.path, throughVPN: on, connection: connection, routing: routing) }
            }
        )
    }
}
