import SwiftUI
import VPNCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Основные", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Внешний вид", systemImage: "paintbrush") }
            ConnectionSettingsView()
                .tabItem { Label("Подключение", systemImage: "network") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    @AppStorage(VPNforYouApp.autoConnectKey) private var autoConnect = false
    @AppStorage(GlobalHotKey.enabledKey) private var hotKey = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Toggle("Открывать при входе в систему", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        do {
                            try LoginItem.set(value)
                            loginError = nil
                        } catch {
                            loginError = "macOS не дала включить автозапуск: \(error.localizedDescription)"
                        }
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                if LoginItem.needsApproval {
                    Text("Разрешите VPNforYou в «Системные настройки → Основные → Объекты входа».")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                }
                Toggle("Подключаться к последнему серверу при запуске", isOn: $autoConnect)
                Toggle(isOn: $hotKey) {
                    Text("Горячая клавиша ⌥⌘V")
                    Text("Включает и выключает VPN из любой программы")
                }
                .onChange(of: hotKey) { GlobalHotKey.shared.apply() }
            }

            Section {
                HStack {
                    Button("Скопировать логи без секретов") {
                        Task {
                            await DiagnosticReport.copy(model: model, connection: connection, routing: routing)
                            copied = true
                        }
                    }
                    if copied {
                        Label("Скопировано", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Если что-то не работает")
            } footer: {
                Text("В отчёт попадают версии, состояние и последние строки логов. Ключи, UUID, IP-адреса и адреса серверов заменяются на [скрыто], [uuid], [ip] и [сервер]. Перед отправкой его можно просмотреть.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}

private struct ConnectionSettingsView: View {
    @Environment(ConnectionManager.self) private var connection
    @AppStorage(Diagnostics.serviceKey) private var ipService: IPService = .ipinfo
    @AppStorage(Diagnostics.checkOnConnectKey) private var checkOnConnect = true

    var body: some View {
        Form {
            Section {
                Picker("Сервис проверки IP", selection: $ipService) {
                    ForEach(IPService.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Проверять IP при подключении", isOn: $checkOnConnect)
            } header: {
                Text("IP-адрес")
            } footer: {
                Text("Запрос уходит только в выбранный сервис: один напрямую и один через VPN, чтобы сравнить адреса. Тест скорости обращается к speed.cloudflare.com, только когда вы его запускаете.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Помощник") {
                    Text(statusText)
                        .foregroundStyle(connection.helperState == .ready ? Palette.ink2 : Palette.warn)
                }
                HStack {
                    Button(connection.helperState == .ready ? "Переустановить" : "Установить") {
                        Task { await connection.installHelper() }
                    }
                    .disabled(connection.helperState == .installing)
                    Button("Удалить помощника", role: .destructive) {
                        Task { await connection.uninstallHelper() }
                    }
                    .disabled(connection.helperState == .notInstalled || connection.helperState == .installing)
                }
                if let error = connection.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                }
            } footer: {
                Text("Помощник работает от имени администратора и включает VPN без пароля при каждом подключении. Он принимает команды только от вашей учётной записи.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await connection.refreshHelperState() }
    }

    private var statusText: String {
        switch connection.helperState {
        case .unknown: "проверяю…"
        case .notInstalled: "не установлен"
        case .outdated: "устарел, нужна переустановка"
        case .ready: "установлен"
        case .installing: "установка…"
        }
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(AppearanceKey.theme) private var theme: AppTheme = .system
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    @AppStorage(AppearanceKey.density) private var density: Density = .comfortable
    @AppStorage(AppearanceKey.material) private var material: WindowMaterial = .glass
    @AppStorage(AppearanceKey.hideIP) private var hideIP = false
    @AppStorage(AppearanceKey.menuIcon) private var menuIcon: MenuIconStyle = .shield
    @AppStorage(AppearanceKey.cards) private var cardsRaw = "ip,server,tiles"

    var body: some View {
        Form {
            Section {
                Picker("Материал", selection: $material) {
                    ForEach(WindowMaterial.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Настоящий Liquid Glass — в macOS 26 Tahoe. На macOS 14–15 вместо него матовое стекло системы.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Тема", selection: $theme) {
                    ForEach(AppTheme.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Акцентный цвет") {
                    HStack(spacing: 10) {
                        ForEach(AccentColor.allCases) { option in
                            AccentSwatch(option: option, isSelected: option == accent) {
                                accent = option
                            }
                        }
                    }
                }

                Picker("Плотность", selection: $density) {
                    ForEach(Density.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $hideIP) {
                    Text("Скрывать IP-адреса")
                    Text("Показывать \(IPMasker.mask("203.0.113.57")) — удобно при демонстрации экрана")
                }
            }

            Section {
                Picker("Иконка в строке меню", selection: $menuIcon) {
                    ForEach(MenuIconStyle.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } footer: {
                Text("«Код страны» и «Скорость» видны, пока VPN подключён; в остальное время — щит.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Главный экран") {
                let layout = CardLayout(cardsRaw)
                ForEach(Array(layout.items.enumerated()), id: \.element.card) { index, item in
                    HStack {
                        Toggle(item.card.title, isOn: Binding(
                            get: { item.visible },
                            set: { value in
                                var updated = layout
                                updated.setVisible(item.card, value)
                                cardsRaw = updated.raw
                            }
                        ))
                        Spacer()
                        Button {
                            var updated = layout
                            updated.move(item.card, by: -1)
                            cardsRaw = updated.raw
                        } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .accessibilityLabel("Выше")
                        Button {
                            var updated = layout
                            updated.move(item.card, by: 1)
                            cardsRaw = updated.raw
                        } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == layout.items.count - 1)
                        .accessibilityLabel("Ниже")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccentSwatch: View {
    let option: AccentColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(option.color)
                .frame(width: 22, height: 22)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.white, lineWidth: 2)
                            .padding(3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
