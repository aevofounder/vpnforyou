import Foundation
import Observation
import VPNCore

/// App state: profiles (subscriptions and hand-added keys), the selected server,
/// import and refresh. Profiles live in the Keychain; only the selected id
/// (a hash, not a secret) goes to UserDefaults.
@MainActor
@Observable
final class AppModel {
    enum Route {
        case home, servers, add, speed
    }

    struct Selection {
        let isGroup: Bool
        let code: String?
        let title: String
        let subtitle: String
        let usage: SubscriptionUsage?
    }

    struct ImportSummary: Equatable {
        var subscriptions = 0
        var servers = 0
        var problems: [String] = []
        var warnings: [String] = []

        var succeeded: Bool { subscriptions > 0 || servers > 0 }
    }

    var route: Route = .home
    private(set) var profiles: [Profile] = []
    private(set) var selectedID: String?
    private(set) var refreshing: Set<UUID> = []
    private(set) var profileErrors: [UUID: String] = [:]
    private(set) var isImporting = false
    private(set) var lastImport: ImportSummary?
    private(set) var recentlyDeleted: (profile: Profile, index: Int)?
    private(set) var storageError: String?

    private let store: ProfileStore
    private let fetcher: SubscriptionFetcher
    @ObservationIgnored private var autoRefresh: Task<Void, Never>?

    private static let selectedKey = "servers.selectedID"
    private static let manualName = "Мои ключи"

    init(
        store: ProfileStore = ProfileStore(secrets: KeychainSecretStore()),
        fetcher: SubscriptionFetcher = SubscriptionFetcher()
    ) {
        self.store = store
        self.fetcher = fetcher
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey)
        load()
        autoRefresh = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDueSubscriptions()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    // MARK: - Reading

    var hasServers: Bool {
        profiles.contains { !$0.visibleServers.isEmpty || !$0.groups.isEmpty }
    }

    var currentSelection: Selection? {
        guard let selectedID else { return nil }
        for profile in profiles {
            if let group = profile.groups.first(where: { $0.id == selectedID }) {
                return Selection(
                    isGroup: true,
                    code: group.countryCode,
                    title: group.displayName,
                    subtitle: "Автовыбор · " + Format.plural(group.memberIDs.count, "сервер", "сервера", "серверов"),
                    usage: profile.usage
                )
            }
            if let server = profile.server(id: selectedID) {
                return Selection(
                    isGroup: false, code: server.countryCode, title: server.displayName,
                    subtitle: server.summary, usage: profile.usage
                )
            }
        }
        return nil
    }

    /// Every visible server of every profile, for pings.
    var allServers: [ServerConfig] {
        profiles.flatMap(\.visibleServers)
    }

    var allGroups: [ServerGroup] {
        profiles.flatMap(\.groups)
    }

    /// Servers and groups of the profile that holds the selection, for a connect request.
    func connectionParts() -> (servers: [ServerConfig], groups: [ServerGroup], selectedID: String)? {
        guard let selectedID else { return nil }
        guard let profile = profiles.first(where: { profile in
            profile.server(id: selectedID) != nil || profile.groups.contains { $0.id == selectedID }
        }) else { return nil }
        return (profile.servers, profile.groups, selectedID)
    }

    /// Display name and country for a server or group id (for the status pill and activity).
    func label(for id: String) -> (code: String?, name: String)? {
        for profile in profiles {
            if let group = profile.groups.first(where: { $0.id == id }) { return (group.countryCode, group.displayName) }
            if let server = profile.server(id: id) { return (server.countryCode, server.displayName) }
        }
        return nil
    }

    func statusLine(for profile: Profile) -> String {
        let count = profile.visibleServers.count + profile.groups.count
        var parts = [Format.plural(count, "сервер", "сервера", "серверов")]
        if profile.subscriptionURL == nil {
            parts.append("добавлены вручную")
        } else if let updatedAt = profile.updatedAt {
            parts.append("обновлено " + Format.relative(updatedAt))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Selection

    func select(_ id: String) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
    }

    /// Keeps the selection valid: the first auto-select group, else the first server.
    private func ensureSelection() {
        if let selectedID, currentSelection != nil, !selectedID.isEmpty { return }
        let first = profiles.lazy.compactMap { $0.groups.first?.id ?? $0.visibleServers.first?.id }.first
        if let first {
            select(first)
        } else {
            selectedID = nil
            UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        }
    }

    // MARK: - Import

    func importText(_ text: String) async {
        isImporting = true
        defer { isImporting = false }

        let input = ImportInput.classify(text)
        var summary = ImportSummary()

        for url in input.subscriptionURLs {
            let label = SubscriptionURL.displayHost(url) ?? "Подписка"
            if SubscriptionURL.isInsecure(url) {
                summary.warnings.append("\(label): ссылка без https, токен подписки виден в сети. Попросите у продавца https-ссылку.")
            }
            do {
                let fetched = try await fetcher.fetch(url)
                if let index = profiles.firstIndex(where: { $0.subscriptionURL == url }) {
                    profiles[index].apply(fetched)
                    profileErrors[profiles[index].id] = nil
                } else {
                    var profile = Profile(name: fetched.title ?? label, source: .subscription(url: url))
                    profile.apply(fetched)
                    profiles.append(profile)
                }
                summary.subscriptions += 1
                summary.servers += fetched.parsed.servers.filter { $0.isHidden != true }.count + fetched.parsed.groups.count
                summary.problems += fetched.parsed.skipped.prefix(3).map { "\($0.name): \($0.reason)" }
            } catch {
                summary.problems.append("\(label): \(Self.message(for: error))")
            }
        }

        if !input.parsed.isEmpty {
            if let index = profiles.firstIndex(where: { $0.source == .manual }) {
                profiles[index].merge(input.parsed)
            } else {
                var manual = Profile(name: Self.manualName, source: .manual)
                manual.merge(input.parsed)
                profiles.append(manual)
            }
            summary.servers += input.parsed.servers.filter { $0.isHidden != true }.count + input.parsed.groups.count
        }
        summary.problems += input.parsed.skipped.prefix(5).map { "\($0.name): \($0.reason)" }
        if input.isEmpty {
            summary.problems.append(ImportError.unrecognizedFormat.message)
        }

        if summary.succeeded {
            ensureSelection()
            save()
        }
        lastImport = summary
    }

    func clearImportSummary() {
        lastImport = nil
    }

    // MARK: - Refresh

    func refresh(_ id: UUID) async {
        guard let url = profiles.first(where: { $0.id == id })?.subscriptionURL, !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            let fetched = try await fetcher.fetch(url)
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].apply(fetched)
            profileErrors[id] = nil
            ensureSelection()
            save()
        } catch {
            profileErrors[id] = Self.message(for: error)
        }
    }

    func refreshDueSubscriptions() async {
        for profile in profiles where profile.needsRefresh() {
            await refresh(profile.id)
        }
    }

    // MARK: - Delete with undo

    func delete(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let removed = profiles.remove(at: index)
        profileErrors[id] = nil
        recentlyDeleted = (removed, index)
        ensureSelection()
        save()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.recentlyDeleted?.profile.id == removed.id { self?.recentlyDeleted = nil }
        }
    }

    func undoDelete() {
        guard let deleted = recentlyDeleted else { return }
        profiles.insert(deleted.profile, at: min(deleted.index, profiles.count))
        recentlyDeleted = nil
        ensureSelection()
        save()
    }

    // MARK: - Storage

    private func load() {
        do {
            profiles = try store.load()
            storageError = nil
        } catch {
            profiles = []
            storageError = "Не удалось прочитать ключи из Связки ключей"
        }
        ensureSelection()
    }

    private func save() {
        do {
            try store.save(profiles)
            storageError = nil
        } catch {
            storageError = "Не удалось сохранить ключи в Связку ключей"
        }
    }

    private static func message(for error: Error) -> String {
        (error as? ImportError)?.message ?? "неизвестная ошибка"
    }
}
