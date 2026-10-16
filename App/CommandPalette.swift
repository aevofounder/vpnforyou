import AppKit
import SwiftUI
import VPNCore

/// ⌘K: search a server, a program or a command and run it with Enter,
/// as in Raycast. Opens without animation: it is used many times a day.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    @Environment(Diagnostics.self) private var diagnostics
    @Environment(InstalledApps.self) private var installed
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    @State private var query: String
    @State private var selection = 0
    @FocusState private var focused: Bool

    init(query: String = "") {
        _query = State(initialValue: query)
    }

    struct Command: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        let icon: String
        var keywords = ""
        let run: @MainActor () -> Void
    }

    var body: some View {
        let results = filtered
        VStack(spacing: 8) {
            ScreenHeader("Быстрые действия")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.ink3)
                TextField("Сервер, программа или команда", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { execute(results, at: selection) }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1, max(0, results.count - 1))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Palette.surface2.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            CommandRow(command: command, isSelected: index == selection)
                                .id(command.id)
                                .onTapGesture { execute(results, at: index) }
                        }
                        if results.isEmpty {
                            Text("Ничего не найдено")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.ink3)
                                .padding(.vertical, 16)
                        }
                    }
                }
                .frame(height: 330)
                .onChange(of: selection) { _, new in
                    if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                }
            }

            Text("↑↓ выбрать · ⏎ выполнить · esc назад")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
        }
        .onAppear {
            focused = true
            installed.loadIfNeeded(listed: routing.allListedPaths)
        }
        .onChange(of: query) { selection = 0 }
    }

    private func execute(_ results: [Command], at index: Int) {
        guard results.indices.contains(index) else { return }
        AppLog.add("Команда: \(results[index].id.split(separator: ":").first ?? "")")
        results[index].run()
    }

    // MARK: - Commands

    private var filtered: [Command] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let all = actions + servers + (words.isEmpty ? [] : apps)
        guard !words.isEmpty else { return all }
        return all.filter { command in
            let haystack = (command.title + " " + (command.subtitle ?? "") + " " + command.keywords).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var actions: [Command] {
        var list: [Command] = []
        if connection.state.isConnected {
            list.append(Command(id: "disconnect", title: "Отключить VPN", icon: "power", keywords: "выключить стоп off") {
                model.route = .home
                Task { await connection.disconnect() }
            })
        } else if model.connectionParts() != nil {
            list.append(Command(id: "connect", title: "Подключить VPN", subtitle: model.currentSelection?.title,
                                icon: "power", keywords: "включить старт on") {
                model.route = .home
                Task { await VPNActions.connect(model: model, connection: connection, routing: routing) }
            })
        }
        if let fastest = PingSort.fastest(model.allServers.map(\.id), pings: diagnostics.pings),
           let server = model.allServers.first(where: { $0.id == fastest }) {
            list.append(Command(id: "fastest", title: "Самый быстрый сервер",
                                subtitle: "\(server.displayName) · \(diagnostics.pings[fastest] ?? 0) мс",
                                icon: "hare.fill", keywords: "быстрый fastest") {
                choose(server.id)
            })
        }
        list += [
            Command(id: "ping", title: "Проверить пинг серверов", icon: "speedometer", keywords: "ping задержка") {
                diagnostics.pingAll(model.allServers, groups: model.allGroups, connection: connection)
                model.route = .servers
            },
            Command(id: "speed", title: "Тест скорости", icon: "gauge.with.dots.needle.67percent",
                    keywords: "speed скорость мбит") {
                model.route = .speed
            },
            Command(id: "ip", title: "Проверить IP", icon: "network", keywords: "ip адрес айпи") {
                diagnostics.checkIP(connection: connection)
                model.route = .home
            },
            Command(id: "apps", title: "Программы", subtitle: "Какие программы идут через VPN",
                    icon: "square.grid.2x2", keywords: "приложения apps split") {
                model.route = .apps
            },
            Command(id: "activity", title: "Активность", subtitle: "Кто сейчас в сети",
                    icon: "waveform.path.ecg", keywords: "соединения connections") {
                model.route = .home
                ActivityWindow.open(connection: connection, routing: routing, installed: installed)
            },
            Command(id: "mode-all", title: "Режим: весь трафик через VPN", icon: "globe",
                    keywords: "режим mode все") { setMode(.all) },
            Command(id: "mode-only", title: "Режим: только выбранные программы", icon: "checklist",
                    keywords: "режим mode только") { setMode(.onlySelected) },
            Command(id: "mode-except", title: "Режим: все, кроме выбранных", icon: "checklist.unchecked",
                    keywords: "режим mode кроме исключить") { setMode(.allExceptSelected) },
            Command(id: "servers", title: "Серверы", icon: "list.bullet", keywords: "регионы страны") {
                model.route = .servers
            },
            Command(id: "add", title: "Добавить ключ или подписку", icon: "plus", keywords: "vless hysteria ключ") {
                model.route = .add
            },
            Command(id: "logs", title: "Скопировать логи без секретов", icon: "doc.on.clipboard",
                    keywords: "логи ошибка отчёт") {
                model.route = .home
                Task { await DiagnosticReport.copy(model: model, connection: connection, routing: routing) }
            },
            Command(id: "updates", title: "Проверить обновления", subtitle: "Версия \(Bundle.main.appVersion), \(Bundle.main.buildDescription)",
                    icon: "arrow.down.circle", keywords: "обновление update версия") {
                model.route = .home
                Updater.shared.checkForUpdates()
            },
            Command(id: "settings", title: "Настройки", icon: "gearshape", keywords: "settings параметры") {
                model.route = .home
                NSApp.activate()
                openSettings()
            },
        ]
        return list
    }

    private var servers: [Command] {
        model.profiles.flatMap(\.entries).map { entry -> Command in
            switch entry {
            case .group(let group):
                Command(id: "server:\(group.id)", title: group.displayName, subtitle: "Автовыбор",
                        icon: "bolt.fill", keywords: (group.countryCode ?? "") + " авто сервер") {
                    choose(group.id)
                }
            case .server(let server):
                Command(id: "server:\(server.id)", title: server.displayName,
                        subtitle: server.summary + (diagnostics.pings[server.id].map { " · \($0) мс" } ?? ""),
                        icon: "globe", keywords: (server.countryCode ?? "") + " сервер") {
                    choose(server.id)
                }
            }
        }
    }

    private var apps: [Command] {
        guard routing.mode != .all else { return [] }
        return installed.apps.map { app in
            let on = routing.goesThroughVPN(app.path)
            return Command(id: "app:\(app.path)", title: app.name,
                           subtitle: on ? "Сейчас через VPN · выключить" : "Сейчас напрямую · пустить через VPN",
                           icon: on ? "checkmark.circle.fill" : "circle", keywords: "программа app") {
                Task { await VPNActions.setApp(app.path, throughVPN: !on, connection: connection, routing: routing) }
            }
        }
    }

    /// Picks a server and connects to it if the VPN is off.
    private func choose(_ id: String) {
        model.route = .home
        Task {
            await VPNActions.select(id, model: model, connection: connection, routing: routing)
            if !connection.state.isConnected, !connection.state.isBusy {
                await VPNActions.connect(model: model, connection: connection, routing: routing)
            }
        }
    }

    private func setMode(_ mode: RoutingMode) {
        model.route = .home
        Task { await VPNActions.setMode(mode, model: model, connection: connection, routing: routing) }
    }
}

private struct CommandRow: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let command: CommandPaletteView.Command
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Palette.ink2)
                .frame(width: 24, height: 24)
                .background(isSelected ? accent.color : Palette.surface2.opacity(0.8),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(command.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isSelected {
                Text("⏎")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink3)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
        .background(isSelected ? accent.color.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Opens the Activity window with the app's stores and appearance.
@MainActor
enum ActivityWindow {
    static func open(connection: ConnectionManager, routing: RoutingStore, installed: InstalledApps) {
        let defaults = UserDefaults.standard
        let accent = defaults.string(forKey: AppearanceKey.accent).flatMap(AccentColor.init(rawValue:)) ?? .blue
        let theme = defaults.string(forKey: AppearanceKey.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        AuxWindow.show(id: "activity", title: "Активность", size: NSSize(width: 640, height: 480)) {
            ActivityView()
                .environment(connection)
                .environment(routing)
                .environment(installed)
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
