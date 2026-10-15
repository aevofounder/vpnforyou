#if DEBUG
import AppKit
import SwiftUI
import VPNCore

/// Debug builds only: `VPNforYou --render-screenshots <folder>` draws every
/// screen with made-up data (example.com servers, documentation IPs) into
/// PNG files and quits. CI uses it to show the design without a real Mac.
@MainActor
enum ScreenshotRenderer {
    static let argument = "--render-screenshots"

    static var outputFolder: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    struct Look {
        var theme: AppTheme = .light
        var accent: AccentColor = .blue
        var material: WindowMaterial = .solid
    }

    static func run(into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: AppearanceKey.hideIP)
        defaults.removeObject(forKey: AppearanceKey.cards)
        defaults.set("comfortable", forKey: AppearanceKey.density)
        defaults.set(false, forKey: Diagnostics.checkOnConnectKey)
        defaults.set(true, forKey: "servers.sortByPing")

        let light = Look()
        await shot("01-home-connected", folder, light) { stores in
            stores.connect()
            return menu(stores, route: .home)
        }
        await shot("02-home-off", folder, light) { stores in
            stores.diagnostics.previewSet(directIP: .done(Fixtures.homeIP), vpnIP: .idle, pings: [:],
                                          speedRun: nil, history: [])
            return menu(stores, route: .home)
        }
        await shot("03-servers", folder, light) { stores in
            stores.connect()
            return menu(stores, route: .servers)
        }
        await shot("04-speed", folder, light) { stores in
            stores.connect()
            return menu(stores, route: .speed)
        }
        await shot("05-apps", folder, light) { stores in
            stores.connect()
            return menu(stores, route: .apps)
        }
        await shot("06-palette", folder, light) { stores in
            stores.connect()
            return menu(stores, route: .palette)
        }
        await shot("07-activity", folder, light, size: CGSize(width: 640, height: 470)) { stores in
            stores.connect()
            let monitor = ActivityMonitor()
            monitor.previewSet(apps: Fixtures.activity, connections: 37)
            return AnyView(stores.inject(ActivityView(monitor: monitor)))
        }
        await shot("08-settings", folder, light, size: CGSize(width: 520, height: 760)) { stores in
            AnyView(stores.inject(AppearanceSettingsView()))
        }
        await shot("09-home-dark", folder, Look(theme: .dark, accent: .violet)) { stores in
            stores.connect()
            return menu(stores, route: .home)
        }
        await shot("10-servers-dark", folder, Look(theme: .dark, accent: .green)) { stores in
            stores.connect()
            return menu(stores, route: .servers)
        }
        await shot("11-home-glass", folder, Look(material: .glass)) { stores in
            stores.connect()
            return menu(stores, route: .home)
        }
        await shot("12-first-run", folder, light) { stores in
            let empty = Stores(profiles: [])
            empty.connection.previewSet(helper: .notInstalled, connectedID: nil, since: nil, traffic: [])
            return menu(empty, route: .home)
        }
    }

    // MARK: - Rendering

    private static func menu(_ stores: Stores, route: AppModel.Route) -> AnyView {
        stores.model.route = route
        return AnyView(stores.inject(MenuContentView()))
    }

    private static func shot(_ name: String, _ folder: URL, _ look: Look, size: CGSize? = nil,
                             build: (Stores) -> AnyView) async {
        let defaults = UserDefaults.standard
        defaults.set(look.theme.rawValue, forKey: AppearanceKey.theme)
        defaults.set(look.accent.rawValue, forKey: AppearanceKey.accent)
        defaults.set(look.material.rawValue, forKey: AppearanceKey.material)

        let stores = Stores(profiles: Fixtures.profiles)
        let root = build(stores)
            .tint(look.accent.color)
            .environment(\.colorScheme, look.theme == .dark ? .dark : .light)

        let hosting = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: look.theme == .dark ? .darkAqua : .aqua)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: size?.width ?? 360, height: size?.height ?? 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.backgroundColor = look.material == .glass ? .windowBackgroundColor : NSColor(Palette.background)
        window.contentView = hosting
        if size == nil { window.setContentSize(hosting.fittingSize) }
        window.orderFrontRegardless()

        try? await Task.sleep(for: .milliseconds(900))
        hosting.layoutSubtreeIfNeeded()
        if size == nil { window.setContentSize(hosting.fittingSize) }
        try? await Task.sleep(for: .milliseconds(400))

        let bounds = hosting.bounds
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) {
            hosting.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent(name + ".png"))
            }
        }
        // The real window as the compositor sees it (glass, shadows), when screen capture is allowed.
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                             folder.appendingPathComponent(name + "-window.png").path]
        if (try? capture.run()) != nil {
            for _ in 0..<50 where capture.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if capture.isRunning { capture.terminate() }
        }
        window.orderOut(nil)
    }

    // MARK: - Stores with made-up data

    @MainActor
    final class Stores {
        let model: AppModel
        let connection = ConnectionManager(checkHelper: false)
        let routing = RoutingStore()
        let diagnostics = Diagnostics()
        let installed = InstalledApps()

        init(profiles: [Profile]) {
            let store = ProfileStore(secrets: InMemorySecretStore())
            try? store.save(profiles)
            model = AppModel(store: store)
            if let first = profiles.first?.servers.first { model.select(first.id) }
            connection.previewSet(helper: .ready, connectedID: nil, since: nil, traffic: [])
            installed.previewSet(apps: Fixtures.apps)
            routing.setMode(.onlySelected)
            for app in Fixtures.apps {
                routing.setThroughVPN(app.path, Fixtures.throughVPN.contains(app.name))
            }
        }

        func connect() {
            let id = Fixtures.profiles[0].servers[0].id
            connection.previewSet(helper: .ready, connectedID: id, since: Date().addingTimeInterval(-761),
                                  traffic: Fixtures.traffic)
            diagnostics.previewSet(directIP: .done(Fixtures.homeIP), vpnIP: .done(Fixtures.vpnIP),
                                   pings: Fixtures.pings, speedRun: Fixtures.speedRun, history: Fixtures.history)
        }

        func inject(_ view: some View) -> some View {
            view
                .environment(model)
                .environment(connection)
                .environment(routing)
                .environment(diagnostics)
                .environment(installed)
        }
    }
}

/// Made-up data: example.com hosts, the zero UUID, documentation IP ranges.
@MainActor
enum Fixtures {
    static let uuid = "00000000-0000-0000-0000-000000000000"
    static let realityKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    static func vless(_ name: String, _ host: String, transport: Transport = .tcp, security: TransportSecurity = .reality) -> ServerConfig {
        ServerConfig(
            name: name, host: host, port: 443,
            settings: .vless(VLESSSettings(
                uuid: uuid, transport: transport, security: security,
                tls: TLSOptions(serverName: "www.example.org", fingerprint: "chrome"),
                reality: security == .reality ? RealityOptions(publicKey: realityKey, shortID: "0a1b") : nil,
                path: transport == .tcp || transport == .grpc ? nil : "/fake",
                serviceName: transport == .grpc ? "fake" : nil
            ))
        )
    }

    static func hysteria(_ name: String, _ host: String) -> ServerConfig {
        ServerConfig(name: name, host: host, port: 443,
                     settings: .hysteria2(Hysteria2Settings(auth: "test-password", tls: TLSOptions(serverName: host),
                                                            obfs: "salamander", obfsPassword: "test-obfs")))
    }

    static let servers: [ServerConfig] = [
        vless("🇳🇱 Нидерланды", "nl.example.com"),
        vless("🇩🇪 Германия", "de.example.com", transport: .xhttp),
        hysteria("🇫🇮 Финляндия", "fi.example.com"),
        vless("🇹🇷 Турция", "tr.example.com", transport: .grpc, security: .tls),
        vless("🇺🇸 США", "us.example.com", transport: .ws, security: .tls),
        vless("🇯🇵 Япония", "jp.example.com"),
    ]

    static var profiles: [Profile] {
        let group = ServerGroup(name: "⚡ Автовыбор", memberIDs: [servers[0].id, servers[1].id, servers[2].id])
        let subscription = Profile(
            name: "Example VPN", source: .subscription(url: "https://sub.example.com/test-token"),
            servers: servers, groups: [group],
            usage: SubscriptionUsage(upload: 4_800_000_000, download: 97_700_000_000, total: 1_000_000_000_000,
                                     expiresAt: Date().addingTimeInterval(24 * 86_400 + 3_600)),
            updatedAt: Date().addingTimeInterval(-25 * 60), updateIntervalHours: 12
        )
        let manual = Profile(name: "Мои ключи", source: .manual,
                             servers: [vless("🇰🇿 Казахстан", "kz.example.net")], updatedAt: Date())
        return [subscription, manual]
    }

    static var pings: [String: Int] {
        let values = [38, 46, 52, 74, 118, 214]
        var result: [String: Int] = [:]
        for (server, ms) in zip(servers, values) { result[server.id] = ms }
        if let group = profiles.first?.groups.first { result[group.id] = 38 }
        return result
    }

    static let homeIP = IPInfo(ip: "203.0.113.57", countryCode: "RU", city: "Москва", organization: "Example Telecom")
    static let vpnIP = IPInfo(ip: "198.51.100.24", countryCode: "NL", city: "Amsterdam", organization: "Example Hosting B.V.")

    static var traffic: [TrafficSample] {
        (0..<60).map { index in
            let t = Double(index)
            let down = 1_800_000 + 1_400_000 * sin(t / 5.5) + 900_000 * sin(t / 1.7 + 1) + (index > 44 ? 2_200_000 : 0)
            let up = 160_000 + 90_000 * sin(t / 3.1 + 2)
            return TrafficSample(up: Int64(max(40_000, up)), down: Int64(max(120_000, down)))
        }
    }

    static let speedRun: Diagnostics.SpeedRun = {
        var run = Diagnostics.SpeedRun(route: .vpn)
        run.phase = .done
        run.latencyMs = 41
        run.downloadMbps = 187.4
        run.uploadMbps = 92.3
        run.bytesUsed = 31_400_000
        return run
    }()

    static let history: [SpeedResult] = [
        SpeedResult(route: .vpn, date: Date().addingTimeInterval(-60), serverName: "Нидерланды",
                    latencyMs: 41, downloadMbps: 187.4, uploadMbps: 92.3, bytesUsed: 31_400_000),
        SpeedResult(route: .direct, date: Date().addingTimeInterval(-600), latencyMs: 12,
                    downloadMbps: 312.8, uploadMbps: 118.0, bytesUsed: 35_000_000),
        SpeedResult(route: .vpn, date: Date().addingTimeInterval(-3_000), serverName: "Германия",
                    latencyMs: 49, downloadMbps: 164.1, uploadMbps: 85.6, bytesUsed: 33_900_000),
    ]

    static let throughVPN: Set<String> = ["Telegram", "Google Chrome", "Discord", "Spotify", "ChatGPT"]

    static var apps: [AppEntry] {
        [
            ("ChatGPT", "/Applications/ChatGPT.app", "com.example.chatgpt"),
            ("Discord", "/Applications/Discord.app", "com.example.discord"),
            ("Firefox", "/Applications/Firefox.app", "org.mozilla.firefox"),
            ("Google Chrome", "/Applications/Google Chrome.app", "com.google.Chrome"),
            ("Microsoft Edge", "/Applications/Microsoft Edge.app", "com.microsoft.edgemac"),
            ("Safari", "/Applications/Safari.app", "com.apple.Safari"),
            ("Spotify", "/Applications/Spotify.app", "com.example.spotify"),
            ("Telegram", "/Applications/Telegram.app", "org.example.telegram"),
            ("Xcode", "/Applications/Xcode.app", "com.apple.dt.Xcode"),
            ("Музыка", "/System/Applications/Music.app", "com.apple.Music"),
            ("Почта", "/System/Applications/Mail.app", "com.apple.mail"),
        ].map { AppEntry(path: $0.1, name: $0.0, bundleID: $0.2) }
    }

    static var activity: [AppActivity] {
        [
            AppActivity(id: "/Applications/Google Chrome.app", name: "Google Chrome", path: "/Applications/Google Chrome.app",
                        connections: 14, viaVPN: 14, direct: 0, downPerSecond: 2_400_000, upPerSecond: 96_000,
                        destinations: ["www.example.com", "cdn.example.net", "api.example.org"]),
            AppActivity(id: "/Applications/Telegram.app", name: "Telegram", path: "/Applications/Telegram.app",
                        connections: 4, viaVPN: 4, direct: 0, downPerSecond: 640_000, upPerSecond: 58_000,
                        destinations: ["chat.example.org", "media.example.net"]),
            AppActivity(id: "/Applications/Safari.app", name: "Safari", path: "/Applications/Safari.app",
                        connections: 6, viaVPN: 2, direct: 4, downPerSecond: 310_000, upPerSecond: 21_000,
                        destinations: ["news.example.com", "static.example.net"]),
            AppActivity(id: "/Applications/Spotify.app", name: "Spotify", path: "/Applications/Spotify.app",
                        connections: 3, viaVPN: 3, direct: 0, downPerSecond: 180_000, upPerSecond: 4_000,
                        destinations: ["audio.example.com"]),
            AppActivity(id: "/Applications/Xcode.app", name: "Xcode", path: "/Applications/Xcode.app",
                        connections: 5, viaVPN: 0, direct: 5, downPerSecond: 52_000, upPerSecond: 9_000,
                        destinations: ["developer.example.com"]),
            AppActivity(id: "mDNSResponder", name: "mDNSResponder", path: nil,
                        connections: 5, viaVPN: 0, direct: 5, downPerSecond: 0, upPerSecond: 0,
                        destinations: ["192.0.2.53"]),
        ]
    }
}
#endif
