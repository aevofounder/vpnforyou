import Foundation
import Observation
import VPNCore
import VPNHelperCore

/// Connects and disconnects through the privileged helper and follows the
/// running core through it (traffic, liveness, server switching). The app
/// never talks to the core's API itself: only the helper can reach it.
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

    /// Login of the running core's local proxy; only in memory.
    private(set) var session: CoreSession?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: CoreStartRequest?

    /// Server and group ids in the running core config.
    var runningIDs: Set<String> {
        guard state.isConnected, let lastRequest else { return [] }
        return Set(lastRequest.servers.map(\.id) + lastRequest.groups.map(\.id))
    }
    var latestTraffic: TrafficSample? { traffic.last }

    init(checkHelper: Bool = true) {
        guard checkHelper else { return }
        Task { await refreshHelperState(stopStaleCore: true) }
    }

    #if DEBUG
    /// Screenshot fixtures (Debug builds only): a connected look without a core.
    func previewSet(helper: HelperState, connectedID: String?, since: Date?, traffic: [TrafficSample]) {
        helperState = helper
        self.connectedID = connectedID
        self.traffic = traffic
        state = since.map { .connected(since: $0) } ?? .disconnected
    }
    #endif

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
        guard let port = PortPicker.freePort() else {
            state = .failed("Нет свободного порта")
            return
        }

        state = .connecting
        AppLog.add("Подключение: режим \(routing.rawValue), серверов в конфиге \(servers.count), групп \(groups.count)")
        let started = Date()
        let session = CoreSession.random(mixedPort: port)
        let request = CoreStartRequest(servers: servers, groups: groups, selectedID: selectedID,
                                       routing: routing, appPaths: appPaths, session: session)
        do {
            let response = try await Self.call(HelperRequest(command: .start, start: request))
            guard response.ok else { throw ConnectError.helper(response.error ?? "неизвестная ошибка") }

            var alive = false
            for _ in 0..<40 {
                if (try? await Self.call(HelperRequest(command: .status)))?.apiReady == true { alive = true; break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard alive else { throw ConnectError.helper("ядро не запустилось") }

            self.session = session
            lastRequest = request
            connectedID = selectedID
            traffic = []
            state = .connected(since: Date())
            AppLog.add(String(format: "Подключено за %.1f с", Date().timeIntervalSince(started)))
            startMonitor()
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
        if known.contains(selectedID), lastRequest?.routing == routing,
           (try? await Self.call(HelperRequest(command: .select, target: selectedID)))?.ok == true {
            connectedID = selectedID
            AppLog.add("Сервер переключён без переподключения")
            return
        }
        await disconnect()
        await connect(servers: servers, groups: groups, selectedID: selectedID, routing: routing, appPaths: appPaths)
    }

    /// Updates the per-app rules on the fly (the helper rewrites the file and reloads it).
    func updateApps(_ paths: [String]) async {
        guard state.isConnected else { return }
        _ = try? await Self.call(HelperRequest(command: .setApps, apps: AppsUpdate(paths: paths)))
        lastRequest?.appPaths = paths
    }

    /// Latency through a server or group of the running config, in milliseconds.
    func delay(_ id: String) async -> Int? {
        guard state.isConnected else { return nil }
        return (try? await Self.call(HelperRequest(command: .delay, target: id), timeout: 12))?.delay
    }

    /// Live connections for the Activity window.
    func connections() async throws -> ConnectionsSnapshot {
        let response = try await Self.call(HelperRequest(command: .connections))
        guard response.ok, let snapshot = response.connections else {
            throw ConnectError.helper(response.error ?? "нет данных")
        }
        return snapshot
    }

    func helperLogs() async -> [String] {
        (try? await Self.call(HelperRequest(command: .logs)))?.logs ?? []
    }

    // MARK: - Monitor

    /// Once a second: traffic totals from the helper turn into a speed sample.
    /// If the core stays unreachable for ~15 s (the helper restarts a crashed
    /// one meanwhile), the connection is reported as failed.
    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var failures = 0
            var previous: (totals: TrafficTotals, date: Date)?
            while !Task.isCancelled {
                let response = try? await ConnectionManager.call(HelperRequest(command: .traffic), timeout: 5)
                if Task.isCancelled { return }
                guard let self else { return }
                if let totals = response?.traffic {
                    failures = 0
                    let now = Date()
                    if let previous {
                        let sample = TrafficTotals.rate(from: previous.totals, to: totals,
                                                        seconds: now.timeIntervalSince(previous.date))
                        self.traffic.append(sample)
                        if self.traffic.count > 60 { self.traffic.removeFirst(self.traffic.count - 60) }
                    }
                    previous = (totals, now)
                } else {
                    failures += 1
                    previous = nil
                    if failures >= 15 {
                        self.session = nil
                        self.connectedID = nil
                        self.state = .failed("Ядро VPN остановилось")
                        AppLog.add("Ядро не отвечает 15 с, VPN выключен")
                        _ = try? await ConnectionManager.call(HelperRequest(command: .stop))
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
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

    nonisolated static func call(_ request: HelperRequest, timeout: Int = 20) async throws -> HelperResponse {
        try await Task.detached(priority: .userInitiated) {
            try HelperClient.send(request, timeoutSeconds: timeout)
        }.value
    }

    private static func describe(_ error: Error) -> String {
        if let socket = error as? SocketError {
            return socket.isNotRunning ? "Помощник не запущен" : "Нет связи с помощником"
        }
        return error.localizedDescription
    }
}
