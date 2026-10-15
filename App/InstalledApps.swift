import AppKit
import Observation
import VPNCore

/// Installed programs for the apps screen, plus ones added by hand.
/// Scanning runs off the main thread; icons are cached.
@MainActor
@Observable
final class InstalledApps {
    private(set) var apps: [AppEntry] = []
    private(set) var isLoading = false
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var loaded = false

    /// Programs added through "Добавить программу…" that are not in the usual folders.
    private static let extraKey = "apps.extra"

    func loadIfNeeded(listed: [String]) {
        guard !loaded else { return }
        loaded = true
        reload(listed: listed)
    }

    func reload(listed: [String]) {
        isLoading = true
        let extras = (UserDefaults.standard.stringArray(forKey: Self.extraKey) ?? []) + listed
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [AppEntry] in
                var apps = AppCatalog.scan(roots: AppCatalog.defaultRoots())
                var known = Set(apps.map(\.path))
                for path in extras where !known.contains(path) {
                    if let entry = AppCatalog.entry(at: path) {
                        apps.append(entry)
                        known.insert(entry.path)
                    }
                }
                return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }.value
            apps = found
            isLoading = false
        }
    }

    /// Adds a program picked by the user; returns its normalized path.
    func add(url: URL) -> AppEntry? {
        guard let entry = AppCatalog.entry(at: url.path), entry.bundleID != AppCatalog.ownBundleID else { return nil }
        if !apps.contains(where: { $0.path == entry.path }) {
            apps.append(entry)
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        var extras = UserDefaults.standard.stringArray(forKey: Self.extraKey) ?? []
        if !extras.contains(entry.path) {
            extras.append(entry.path)
            UserDefaults.standard.set(Array(extras.suffix(200)), forKey: Self.extraKey)
        }
        return entry
    }

    func entry(for path: String) -> AppEntry? {
        apps.first { $0.path == path }
    }

    func icon(for path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        icons[path] = icon
        return icon
    }
}
