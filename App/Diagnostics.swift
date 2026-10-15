import Foundation
import Observation
import SwiftUI
import VPNCore

/// IP checks, server pings and speed tests. Results stay in memory only.
@MainActor
@Observable
final class Diagnostics {
    enum Lookup: Equatable, Sendable {
        case idle, loading
        case done(IPInfo)
        case failed(String)

        var info: IPInfo? {
            if case .done(let info) = self { return info }
            return nil
        }
    }

    enum SpeedPhase: Equatable {
        case latency, download, upload, done, failed(String)
    }

    struct SpeedRun: Equatable {
        var route: SpeedRoute
        var phase: SpeedPhase = .latency
        var latencyMs: Double?
        var downloadMbps: Double?
        var uploadMbps: Double?
        /// Current speed of the running phase, for the big number.
        var liveMbps: Double?
        var bytesUsed: Int64 = 0

        var isRunning: Bool { [.latency, .download, .upload].contains(phase) }
    }

    private(set) var directIP: Lookup = .idle
    private(set) var vpnIP: Lookup = .idle
    private(set) var pings: [String: Int] = [:]
    /// Servers whose ping could not be measured (timeout, UDP while off).
    private(set) var pingFailed: Set<String> = []
    private(set) var isPinging = false
    private(set) var speedRun: SpeedRun?
    private(set) var speedHistory: [SpeedResult] = []

    @ObservationIgnored private var ipTask: Task<Void, Never>?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?

    static let serviceKey = "network.ipService"
    static let checkOnConnectKey = "network.checkIPOnConnect"

    var service: IPService {
        UserDefaults.standard.string(forKey: Self.serviceKey).flatMap(IPService.init(rawValue:)) ?? .ipinfo
    }

    var ipChanged: Bool? {
        IPLookup.changed(direct: directIP.info, vpn: vpnIP.info)
    }

    // MARK: - IP

    /// Looks up the IP without VPN and, when connected, through it.
    func checkIP(connection: ConnectionManager) {
        ipTask?.cancel()
        let service = service
        let core = connection.state.isConnected ? connection.session : nil
        directIP = .loading
        vpnIP = core == nil ? .idle : .loading
        ipTask = Task { [weak self] in
            async let direct = Self.lookup(service: service, route: .direct, core: nil)
            async let vpn = Self.lookupThroughVPN(service: service, core: core)
            let (directResult, vpnResult) = await (direct, vpn)
            guard !Task.isCancelled, let self else { return }
            self.directIP = directResult
            if let vpnResult { self.vpnIP = vpnResult }
        }
    }

    /// Called when the connection changes: forget the VPN IP, optionally re-check.
    func connectionChanged(connection: ConnectionManager) {
        pings = [:]
        pingFailed = []
        switch connection.state {
        case .connected:
            if UserDefaults.standard.object(forKey: Self.checkOnConnectKey) as? Bool ?? true {
                checkIP(connection: connection)
            }
        case .disconnected, .failed:
            ipTask?.cancel()
            vpnIP = .idle
        default:
            break
        }
    }

    private nonisolated static func lookupThroughVPN(service: IPService, core: CoreSession?) async -> Lookup? {
        guard let core else { return nil }
        return await lookup(service: service, route: .vpn, core: core)
    }

    private nonisolated static func lookup(service: IPService, route: SpeedRoute, core: CoreSession?) async -> Lookup {
        do {
            return .done(try await NetworkProbe.lookupIP(service: service, route: route, core: core))
        } catch is CancellationError {
            return .idle
        } catch let error as NetworkProbe.ProbeError {
            return .failed(error.localizedDescription)
        } catch {
            return .failed("\(service.title) не ответил")
        }
    }

    // MARK: - Ping

    /// Pings the given servers. Connected: the core's URL test through each
    /// server of the running config. Disconnected: a TCP handshake (VLESS only,
    /// Hysteria2 runs over UDP).
    func pingAll(_ servers: [ServerConfig], groups: [ServerGroup], connection: ConnectionManager) {
        pingTask?.cancel()
        isPinging = true
        let client = connection.state.isConnected ? connection.client : nil
        let running = connection.runningIDs
        var targets: [(id: String, host: String, port: Int, tcp: Bool)] = servers.map {
            ($0.id, $0.host, $0.port, $0.proxyProtocol == .vless)
        } + (client == nil ? [] : groups.map { ($0.id, "", 0, false) })
        // While connected only servers of the running config can be measured.
        if client != nil { targets = targets.filter { running.contains($0.id) } }
        var seen = Set<String>()
        targets = targets.filter { seen.insert($0.id).inserted }

        pingTask = Task { [weak self] in
            await withTaskGroup(of: (String, Int?).self) { group in
                var iterator = targets.makeIterator()
                func addNext() -> Bool {
                    guard let target = iterator.next() else { return false }
                    group.addTask {
                        if let client {
                            return (target.id, await client.delay(target.id))
                        }
                        guard target.tcp else { return (target.id, nil) }
                        return (target.id, await NetworkProbe.tcpPing(host: target.host, port: target.port))
                    }
                    return true
                }
                var started = 0
                while started < 8, addNext() { started += 1 }
                while let (id, ms) = await group.next() {
                    guard let self, !Task.isCancelled else { continue }
                    if let ms {
                        self.pings[id] = ms
                        self.pingFailed.remove(id)
                    } else {
                        self.pings[id] = nil
                        self.pingFailed.insert(id)
                    }
                    _ = addNext()
                }
            }
            if !Task.isCancelled { self?.isPinging = false }
        }
    }

    // MARK: - Speed

    func startSpeedTest(route: SpeedRoute, connection: ConnectionManager, serverName: String?) {
        guard speedRun?.isRunning != true else { return }
        let core = route == .vpn ? connection.session : nil
        if route == .vpn, core == nil {
            speedRun = SpeedRun(route: route, phase: .failed("Сначала подключите VPN"))
            return
        }
        speedRun = SpeedRun(route: route)
        speedTask = Task { [weak self] in
            let tester = SpeedTester(route: route, core: core)
            defer { tester.invalidate() }

            let latency = await tester.latency()
            guard let self, !Task.isCancelled else { return }
            guard let latency else {
                self.speedRun?.phase = .failed("speed.cloudflare.com не ответил")
                return
            }
            self.speedRun?.latencyMs = latency
            self.speedRun?.phase = .download

            let download = await tester.download { [weak self] mbps in
                Task { @MainActor in self?.updateLive(mbps, phase: .download) }
            }
            guard !Task.isCancelled else { return }
            self.speedRun?.downloadMbps = download.megabitsPerSecond
            self.speedRun?.bytesUsed += download.bytes
            self.speedRun?.liveMbps = nil
            self.speedRun?.phase = .upload

            let upload = await tester.upload { [weak self] mbps in
                Task { @MainActor in self?.updateLive(mbps, phase: .upload) }
            }
            guard !Task.isCancelled else { return }
            self.speedRun?.uploadMbps = upload.megabitsPerSecond
            self.speedRun?.bytesUsed += upload.bytes
            self.speedRun?.liveMbps = nil

            guard let run = self.speedRun else { return }
            if run.downloadMbps == nil, run.uploadMbps == nil {
                self.speedRun?.phase = .failed("Тест прервался, попробуйте ещё раз")
                return
            }
            self.speedRun?.phase = .done
            let result = SpeedResult(route: route, serverName: route == .vpn ? serverName : nil,
                                     latencyMs: run.latencyMs, downloadMbps: run.downloadMbps,
                                     uploadMbps: run.uploadMbps, bytesUsed: run.bytesUsed)
            self.speedHistory.insert(result, at: 0)
            if self.speedHistory.count > 10 { self.speedHistory.removeLast() }
        }
    }

    func cancelSpeedTest() {
        speedTask?.cancel()
        speedTask = nil
        if speedRun?.isRunning == true { speedRun = nil }
    }

    private func updateLive(_ mbps: Double, phase: SpeedPhase) {
        guard speedRun?.phase == phase else { return }
        speedRun?.liveMbps = mbps
    }
}
