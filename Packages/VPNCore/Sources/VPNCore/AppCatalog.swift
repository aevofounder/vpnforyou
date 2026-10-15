import Foundation

/// An installed program that can be sent through the VPN or around it.
public struct AppEntry: Equatable, Hashable, Identifiable, Sendable {
    /// Bundle path with symlinks resolved, as the core sees the process path.
    public let path: String
    public let name: String
    public let bundleID: String?

    public var id: String { path }

    public init(path: String, name: String, bundleID: String?) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
    }

    /// Apple apps that load pages through system processes (WebKit,
    /// nsurlsessiond): per-app routing only partly applies to them.
    public var usesSystemNetworking: Bool {
        guard let bundleID else { return false }
        return AppCatalog.systemNetworkingBundleIDs.contains(bundleID)
    }
}

/// Finds .app bundles in the usual folders.
public enum AppCatalog {
    public static let ownBundleID = "io.github.aevofounder.vpnforyou"

    public static let systemNetworkingBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.mail", "com.apple.AppStore", "com.apple.Music", "com.apple.TV",
        "com.apple.podcasts", "com.apple.news", "com.apple.Maps", "com.apple.weather", "com.apple.MobileSMS",
    ]

    public static func defaultRoots(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", "/System/Applications", (home as NSString).appendingPathComponent("Applications")]
    }

    /// Bundles in the roots and one folder level below them
    /// (e.g. /Applications/Utilities), deduplicated after resolving symlinks.
    public static func scan(roots: [String], fileManager: FileManager = .default) -> [AppEntry] {
        var seen = Set<String>()
        var result: [AppEntry] = []

        func add(_ path: String) {
            guard let entry = entry(at: path, fileManager: fileManager), entry.bundleID != ownBundleID,
                  seen.insert(entry.path).inserted else { return }
            result.append(entry)
        }

        for root in roots {
            guard let items = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for item in items where !item.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    add(path)
                } else if isDirectory(path, fileManager: fileManager),
                          let inner = try? fileManager.contentsOfDirectory(atPath: path) {
                    for nested in inner where nested.hasSuffix(".app") && !nested.hasPrefix(".") {
                        add((path as NSString).appendingPathComponent(nested))
                    }
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads one bundle; nil if it is not an .app directory.
    public static func entry(at path: String, fileManager: FileManager = .default) -> AppEntry? {
        guard let resolved = normalize(path), isDirectory(resolved, fileManager: fileManager) else { return nil }
        let plistPath = (resolved as NSString).appendingPathComponent("Contents/Info.plist")
        var bundleID: String?
        if let data = fileManager.contents(atPath: plistPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            bundleID = plist["CFBundleIdentifier"] as? String
        }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return AppEntry(path: resolved, name: fileName, bundleID: bundleID)
    }

    /// Absolute, symlink-free path ending in ".app", or nil.
    public static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        guard resolved.hasSuffix(".app"), !resolved.contains("/../"),
              !resolved.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return resolved
    }

    private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// What the Activity screen shows per program.
public struct AppActivity: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var path: String?
    public var connections: Int
    public var viaVPN: Int
    public var direct: Int
    public var downPerSecond: Int64
    public var upPerSecond: Int64
    public var destinations: [String]

    public init(id: String, name: String, path: String?, connections: Int, viaVPN: Int, direct: Int,
                downPerSecond: Int64, upPerSecond: Int64, destinations: [String]) {
        self.id = id
        self.name = name
        self.path = path
        self.connections = connections
        self.viaVPN = viaVPN
        self.direct = direct
        self.downPerSecond = downPerSecond
        self.upPerSecond = upPerSecond
        self.destinations = destinations
    }

    /// Some connections go through the VPN and some around it.
    public var isMixed: Bool { viaVPN > 0 && direct > 0 }
}

public enum ActivitySummary {
    /// Groups connection rows by program, busiest first.
    public static func byApp(_ rows: [ConnectionRates.Row]) -> [AppActivity] {
        var order: [String] = []
        var apps: [String: AppActivity] = [:]
        for row in rows {
            let key = row.appPath ?? row.appName
            if apps[key] == nil {
                order.append(key)
                apps[key] = AppActivity(id: key, name: row.appName, path: row.appPath, connections: 0, viaVPN: 0,
                                        direct: 0, downPerSecond: 0, upPerSecond: 0, destinations: [])
            }
            apps[key]!.connections += 1
            if row.isDirect { apps[key]!.direct += 1 } else { apps[key]!.viaVPN += 1 }
            apps[key]!.downPerSecond += row.downPerSecond
            apps[key]!.upPerSecond += row.upPerSecond
            if !apps[key]!.destinations.contains(row.destination), apps[key]!.destinations.count < 5 {
                apps[key]!.destinations.append(row.destination)
            }
        }
        return order.compactMap { apps[$0] }.sorted { lhs, rhs in
            let left = lhs.downPerSecond + lhs.upPerSecond
            let right = rhs.downPerSecond + rhs.upPerSecond
            if left != right { return left > right }
            if lhs.connections != rhs.connections { return lhs.connections > rhs.connections }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
