import SwiftUI
import VPNCore

/// Servers screen: subscriptions with traffic and expiry, auto-select groups
/// and servers, each as its own tile.
struct ServersView: View {
    @Environment(AppModel.self) private var model
    @Environment(Diagnostics.self) private var diagnostics
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    @AppStorage("servers.sortByPing") private var sortByPing = false

    var body: some View {
        VStack(spacing: 8) {
            ScreenHeader("Серверы") {
                Menu {
                    Picker("Порядок", selection: $sortByPing) {
                        Text("Как в подписке").tag(false)
                        Text("По пингу").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .glassButtonStyle()
                .buttonBorderShape(.circle)
                .fixedSize()
                .help("Сортировка")
                .accessibilityLabel("Сортировка")

                Button {
                    diagnostics.pingAll(model.allServers, groups: model.allGroups, connection: connection)
                } label: {
                    Group {
                        if diagnostics.isPinging {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "speedometer")
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
                }
                .glassButtonStyle()
                .buttonBorderShape(.circle)
                .disabled(diagnostics.isPinging || !model.hasServers)
                .help("Проверить пинг")
                .accessibilityLabel("Проверить пинг")

                Button {
                    model.route = .add
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .glassButtonStyle()
                .buttonBorderShape(.circle)
                .help("Добавить ключ или подписку")
                .accessibilityLabel("Добавить ключ или подписку")
            }

            if model.profiles.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Пока пусто")
                            .font(.system(size: 13, weight: .medium))
                        Text("Добавьте ссылку на подписку или ключи vless:// и hysteria2://.")
                            .foregroundStyle(Palette.ink2)
                        Button("Добавить") { model.route = .add }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                if let fastest = fastestServer {
                    FastestRow(server: fastest, ping: diagnostics.pings[fastest.id] ?? 0,
                               isSelected: model.selectedID == fastest.id) {
                        Task { await VPNActions.select(fastest.id, model: model, connection: connection, routing: routing) }
                    }
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.profiles) { profile in
                            ProfileSection(profile: profile, sortByPing: sortByPing)
                        }
                    }
                }
                .frame(height: listHeight)
            }

            if let deleted = model.recentlyDeleted {
                UndoToast(text: "«\(deleted.profile.name)» удалена", actionTitle: "Вернуть") {
                    model.undoDelete()
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.recentlyDeleted?.profile.id)
    }

    private var fastestServer: ServerConfig? {
        let servers = model.allServers
        guard let id = PingSort.fastest(servers.map(\.id), pings: diagnostics.pings) else { return nil }
        return servers.first { $0.id == id }
    }

    /// ScrollView needs an explicit height inside the menu bar window.
    private var listHeight: CGFloat {
        let rows = model.profiles.reduce(0) { $0 + $1.visibleServers.count + $1.groups.count }
        let estimate = CGFloat(rows) * 50 + CGFloat(model.profiles.count) * 110
        return min(460, max(160, estimate))
    }
}

private struct ProfileSection: View {
    @Environment(AppModel.self) private var model
    @Environment(ConnectionManager.self) private var connection
    @Environment(RoutingStore.self) private var routing
    @Environment(Diagnostics.self) private var diagnostics
    let profile: Profile
    let sortByPing: Bool

    private var servers: [ServerConfig] {
        guard sortByPing else { return profile.visibleServers }
        var seen = Set<String>()
        let ids = profile.visibleServers.map(\.id).filter { seen.insert($0).inserted }
        let order = PingSort.byPing(ids, pings: diagnostics.pings)
        let byID = Dictionary(profile.visibleServers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let usage = profile.usage {
                    UsageView(usage: usage)
                }
                if let error = model.profileErrors[profile.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warn)
                }

                VStack(spacing: 6) {
                    ForEach(profile.groups) { group in
                        ServerRowButton(
                            code: group.countryCode,
                            title: group.displayName,
                            subtitle: "Автовыбор · " + Format.plural(group.memberIDs.count, "сервер", "сервера", "серверов"),
                            isGroup: true,
                            isSelected: model.selectedID == group.id,
                            ping: diagnostics.pings[group.id]
                        ) { choose(group.id) }
                    }
                    ForEach(servers) { server in
                        ServerRowButton(
                            code: server.countryCode,
                            title: server.displayName,
                            subtitle: server.summary,
                            isGroup: false,
                            isSelected: model.selectedID == server.id,
                            ping: diagnostics.pings[server.id],
                            pingFailed: diagnostics.pingFailed.contains(server.id)
                        ) { choose(server.id) }
                    }
                }

                if let first = profile.skipped.first {
                    Text("Пропущено: \(profile.skipped.count). \(first.reason)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                }
            }
        }
    }

    private func choose(_ id: String) {
        Task { await VPNActions.select(id, model: model, connection: connection, routing: routing) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(model.statusLine(for: profile))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 6)
            if profile.subscriptionURL != nil {
                if model.refreshing.contains(profile.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Button {
                        Task { await model.refresh(profile.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink2)
                    .help("Обновить подписку")
                    .accessibilityLabel("Обновить подписку")
                }
            }
            Menu {
                Button("Удалить", role: .destructive) { model.delete(profile.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Palette.ink2)
            .accessibilityLabel("Действия с подпиской")
        }
    }
}

/// "Самый быстрый · NL-1 · 42 мс" after a ping check, one click to pick it.
private struct FastestRow: View {
    @AppStorage(AppearanceKey.accent) private var accent: AccentColor = .blue
    let server: ServerConfig
    let ping: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "hare.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Самый быстрый")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                    Text(server.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                PingBadge(milliseconds: ping, failed: false)
                Text(isSelected ? "Выбран" : "Выбрать")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.ink3 : accent.color)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(accent.color.opacity(0.10), in: shape)
            .overlay(shape.strokeBorder(accent.color.opacity(0.3)))
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .disabled(isSelected)
    }
}
