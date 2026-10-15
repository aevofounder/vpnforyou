import Foundation
import Observation
import VPNCore
import VPNHelperCore

/// Connects and disconnects through the privileged helper and follows the
/// running core through its local API (traffic, liveness, server switching).
@MainActor
@Observable
final class ConnectionManager {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected(since: Date)
        case disconnecting
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var isBusy: Bool { self == .connecting || self == .disconnecting }
    }

    enum HelperState: Equatable {
        case unknown, notInstalled, outdated, ready, installing
    }

    private(set) var state: State = .disconnected {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }
    /// Lets other stores react to connecting and disconnecting (IP check, pings).
    @ObservationIgnored var onStateChange: (@MainActor (State) -> Void)?
    private(set) var helperState: HelperState = .unknown
    private(set) var connectedID: String?
    private(set) var traffic: [TrafficSample] = []
    private(set) var lastError: String?

    /// Secrets of the running core; only in memory.
    private(set) var session: CoreSession?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: CoreStartRequest?

    var client: MihomoClient? { session.map(MihomoClient.init(session:)) }

    /// Server and group ids in the running core config.
    var runningIDs: Set<String> {
        guard state.isConnected, let lastRequest else { return [] }
        return Set(lastRequest.servers.map(\.id) + lastRequest.groups.map(\.id))
    }
    var latestTraffic: TrafficSample? { traffic.last }

    init() {
        Task { await refreshHelperState(stopStaleCore: true) }
    }

    // MARK: - Helper

    func refreshHelperState(stopStaleCore: Bool = false) async {
        do {
            let response = try await Self.call(HelperRequest(command: .hello))
            guard response.helperVersion == HelperProtocol.version else {
                helperState = .outdated
                return
            }
            helperState = .ready
            // A core left over from a previous run of the app: its secrets are gone, stop it.
            if stopStaleCore, response.running == true, session == nil {
                _ = try? await Self.call(HelperRequest(command: .stop))
            }
        } catch let error as SocketError where error.isNotRunning {
            helperState = .notInstalled
        } catch {
            helperState = .notInstalled
        }
    }

    func installHelper() async {
        helperState = .installing
        lastError = nil
        AppLog.add("Установка помощника")
        do {
            try await HelperInstaller.install()
            // launchd starts the helper; give it a moment to open its socket.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                await refreshHelperState()
                if helperState == .ready { return }
            }
            lastError = "Помощник установлен, но не отвечает. Перезагрузите Mac и попробуйте снова."
            AppLog.add("Помощник не ответил после установки")
        } catch {
            lastError = error.localizedDescription
            AppLog.add("Помощник не установлен: \(error.localizedDescription)")
            await refreshHelperState()
        }
    }

    func uninstallHelper() async {
        await disconnect()
        do {
            try await HelperInstaller.uninstall()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshHelperState()
    }

    // MARK: - Connect

    func connect(servers: [ServerConfig], groups: [ServerGroup], selectedID: String,
                 routing: RoutingMode, appPaths: [String]) async {
        guard !state.isBusy else { return }
        lastError = nil
        if helperState != .ready { await refreshHelperState() }
        guard helperState == .ready else {
            state = .failed(helperState == .outdated ? "Обновите помощника" : "Нужно установить помощника")
            return
        }
        guard let ports = PortPicker.pair() else {
            state = .failed("Нет свободных портов")
            return
        }

        state = .connecting
        AppLog.add("Подключение: режим \(routing.rawValue), серверов в конфиге \(servers.count), групп \(groups.count)")
        let started = Date()
        let session = CoreSession.random(controllerPort: ports.0, mixedPort: ports.1)
        let request = CoreStartRequest(servers: servers, groups: groups, selectedID: selectedID,
                                       routing: routing, appPaths: appPaths, session: session)
        do {
            let response = try await Self.call(HelperRequest(command: .start, start: request))
            guard response.ok else { throw ConnectError.helper(response.error ?? "неизвестная ошибка") }

            let client = MihomoClient(session: session)
            var alive = false
            for _ in 0..<40 {
                if await client.isAlive() { alive = true; break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard alive else { throw ConnectError.helper("ядро не запустилось") }

            self.session = session
            lastRequest = request
            connectedID = selectedID
            traffic = []
            state = .connected(since: Date())
            AppLog.add(String(format: "Подключено за %.1f с", Date().timeIntervalSince(started)))
            startMonitor(client)
        } catch {
            _ = try? await Self.call(HelperRequest(command: .stop))
            self.session = nil
            state = .failed(Self.describe(error))
            AppLog.add("Ошибка подключения: \(Self.describe(error))")
        }
    }

    func disconnect() async {
        guard state != .disconnected else { return }
        state = .disconnecting
        AppLog.add("Отключение")
        monitor?.cancel()
        monitor = nil
        _ = try? await Self.call(HelperRequest(command: .stop))
        session = nil
        lastRequest = nil
        connectedID = nil
        traffic = []
        state = .disconnected
    }

    /// Switches the server while connected: instantly if the running config
    /// already has it, otherwise by reconnecting with a fresh config.
    func switchTo(servers: [ServerConfig], groups: [ServerGroup], selectedID: String,
                  routing: RoutingMode, appPaths: [String]) async {
        guard state.isConnected else { return }
        let known = Set((lastRequest?.servers.map(\.id) ?? []) + (lastRequest?.groups.map(\.id) ?? []))
        if known.contains(selectedID), lastRequest?.routing == routing, let client {
            do {
                try await client.select(selectedID)
                connectedID = selectedID
                AppLog.add("Сервер переключён без переподключения")
                return
            } catch {
                // Fall through to a reconnect.
            }
        }
        await disconnect()
        await connect(servers: servers, groups: groups, selectedID: selectedID, routing: routing, appPaths: appPaths)
    }

    /// Updates the per-app rules on the fly.
    func updateApps(_ paths: [String]) async {
        guard state.isConnected else { return }
        _ = try? await Self.call(HelperRequest(command: .setApps, apps: AppsUpdate(paths: paths)))
        lastRequest?.appPaths = paths
        await client?.reloadApps()
    }

    func helperLogs() async -> [String] {
        (try? await Self.call(HelperRequest(command: .logs)))?.logs ?? []
    }

    // MARK: - Monitor

    private func startMonitor(_ client: MihomoClient) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    for try await sample in client.traffic() {
                        failures = 0
                        guard let self else { return }
                        self.traffic.append(sample)
                        if self.traffic.count > 60 { self.traffic.removeFirst(self.traffic.count - 60) }
                    }
                } catch {
                    // Stream dropped: check below whether the core is still there.
                }
                if Task.isCancelled { return }
                if await client.isAlive() {
                    failures = 0
                } else {
                    failures += 1
                    // The helper restarts a crashed core; give it ~15 s before giving up.
                    if failures >= 6 {
                        guard let self else { return }
                        self.session = nil
                        self.connectedID = nil
                        self.state = .failed("Ядро VPN остановилось")
                        AppLog.add("Ядро не отвечает 15 с, VPN выключен")
                        _ = try? await ConnectionManager.call(HelperRequest(command: .stop))
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    // MARK: - Helpers

    enum ConnectError: LocalizedError {
        case helper(String)
        var errorDescription: String? {
            switch self {
            case .helper(let message): message
            }
        }
    }

    nonisolated static func call(_ request: HelperRequest) async throws -> HelperResponse {
        try await Task.detached(priority: .userInitiated) {
            try HelperClient.send(request)
        }.value
    }

    private static func describe(_ error: Error) -> String {
        if let socket = error as? SocketError {
            return socket.isNotRunning ? "Помощник не запущен" : "Нет связи с помощником"
        }
        return error.localizedDescription
    }
}
