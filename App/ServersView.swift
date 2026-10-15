import SwiftUI
import VPNCore

/// Servers screen: subscriptions with traffic and expiry, auto-select groups
/// and servers, each as its own tile.
struct ServersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ScreenHeader("Серверы") {
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
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.profiles) { profile in
                            ProfileSection(profile: profile)
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

    /// ScrollView needs an explicit height inside the menu bar window.
    private var listHeight: CGFloat {
        let rows = model.profiles.reduce(0) { $0 + $1.visibleServers.count + $1.groups.count }
        let estimate = CGFloat(rows) * 50 + CGFloat(model.profiles.count) * 110
        return min(460, max(160, estimate))
    }
}

private struct ProfileSection: View {
    @Environment(AppModel.self) private var model
    let profile: Profile

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
                            isSelected: model.selectedID == group.id
                        ) { model.select(group.id) }
                    }
                    ForEach(profile.visibleServers) { server in
                        ServerRowButton(
                            code: server.countryCode,
                            title: server.displayName,
                            subtitle: server.summary,
                            isGroup: false,
                            isSelected: model.selectedID == server.id
                        ) { model.select(server.id) }
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
