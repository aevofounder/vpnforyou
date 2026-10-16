import Foundation
import VPNCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum HelperError: Error, Equatable {
    case notRunning
    case unknownTarget
    case coreRefused(Int)

    public var message: String {
        switch self {
        case .notRunning: "ядро не запущено"
        case .unknownTarget: "такого сервера нет в текущем подключении"
        case .coreRefused(let status): "ядро ответило \(status)"
        }
    }
}

/// Runs mihomo for the helper: writes the config and the per-app rules into a
/// root-only folder, starts the core, restarts it if it crashes, stops it.
public final class CoreSupervisor: @unchecked Sendable {
    public let corePath: String
    public let runDirectory: String
    /// Pause before restarting a crashed core.
    public var restartDelay: TimeInterval = 2
    public var maxRestarts = 5

    private let lock = NSLock()
    private var process: Process?
    private var request: CoreStartRequest?
    private var wantsRunning = false
    private var restarts = 0

    public init(corePath: String, runDirectory: String) {
        self.corePath = corePath
        self.runDirectory = runDirectory
    }

    public var configPath: String { runDirectory + "/config.json" }
    public var apiSocketPath: String { runDirectory + "/" + HelperProtocol.apiSocketName }
    public var appsPath: String { runDirectory + "/" + MihomoConfigBuilder.appsFileName }
    public var logPath: String { runDirectory + "/core.log" }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    // MARK: - Commands

    public func start(_ request: CoreStartRequest) throws {
        try MihomoConfigBuilder.validate(request)
        let config = try MihomoConfigBuilder.configData(for: request, appsRulesPath: appsPath, apiSocketPath: apiSocketPath)
        let apps = Data(MihomoConfigBuilder.appsRules(paths: request.appPaths).utf8)

        lock.lock()
        defer { lock.unlock() }
        terminateLocked()
        try prepareDirectory()
        try? FileManager.default.removeItem(atPath: apiSocketPath)
        try writeSecure(apps, to: appsPath)
        try writeSecure(config, to: configPath)
        self.request = request
        wantsRunning = true
        restarts = 0
        try launchLocked()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        wantsRunning = false
        terminateLocked()
        request = nil
        try? FileManager.default.removeItem(atPath: configPath)
        try? FileManager.default.removeItem(atPath: apiSocketPath)
    }

    /// Rewrites the per-app rules and asks the core to re-read them at once.
    public func setApps(_ paths: [String]) throws {
        lock.lock()
        guard var current = request else {
            lock.unlock()
            return
        }
        current.appPaths = paths
        do {
            try MihomoConfigBuilder.validate(current)
            try writeSecure(Data(MihomoConfigBuilder.appsRules(paths: paths).utf8), to: appsPath)
        } catch {
            lock.unlock()
            throw error
        }
        request = current
        let reload = current.routing != .all
        lock.unlock()
        if reload { _ = try? api(.reloadApps) }
    }

    // MARK: - Core API (only fixed, checked calls)

    /// Server and group ids of the running config.
    public var runningIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let request else { return [] }
        return Set(request.servers.map(\.id) + request.groups.map(\.id))
    }

    /// The core answers on its API socket.
    public var apiReady: Bool {
        guard isRunning, let response = try? api(.version, timeout: 2) else { return false }
        return response.status == 200
    }

    public func select(_ id: String) throws {
        guard isRunning else { throw HelperError.notRunning }
        guard runningIDs.contains(id) else { throw HelperError.unknownTarget }
        let response = try api(.select(id))
        guard response.status == 204 else { throw HelperError.coreRefused(response.status) }
    }

    /// Latency in milliseconds through a server or group; nil on timeout.
    public func delay(_ id: String) throws -> Int? {
        guard isRunning else { throw HelperError.notRunning }
        guard runningIDs.contains(id) else { throw HelperError.unknownTarget }
        let response = try api(.delay(id), timeout: 8)
        guard response.status == 200 else { return nil }
        return (try? JSONDecoder().decode(DelayResult.self, from: response.body))?.delay
    }

    /// Live connections, at most `limit` of them (busiest last are dropped).
    public func connections(limit: Int = 1_000) throws -> ConnectionsSnapshot {
        let response = try api(.connections)
        guard response.status == 200 else { throw HelperError.coreRefused(response.status) }
        var snapshot = try ConnectionsSnapshot.parse(response.body)
        if snapshot.connections.count > limit { snapshot.connections = Array(snapshot.connections.prefix(limit)) }
        return snapshot
    }

    public func trafficTotals() throws -> TrafficTotals {
        let snapshot = try connections(limit: 0)
        return TrafficTotals(upload: snapshot.uploadTotal, download: snapshot.downloadTotal)
    }

    func api(_ request: MihomoRequest, timeout: Int = 10) throws -> UnixHTTPClient.Response {
        guard isRunning else { throw HelperError.notRunning }
        // mihomo makes its socket 0666; the 0700 root folder already keeps others
        // out, and 0600 on the socket itself is a second lock.
        chmod(apiSocketPath, 0o600)
        return try UnixHTTPClient.send(request, socketPath: apiSocketPath, timeoutSeconds: timeout)
    }

    /// Last lines of the core log with secrets masked.
    public func logTail(lines: Int = 200) -> [String] {
        guard let data = FileManager.default.contents(atPath: logPath) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .map { LogRedactor.redact(String($0)) }
    }

    // MARK: - Process

    private func launchLocked() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = ["-d", runDirectory, "-f", configPath]
        process.currentDirectoryURL = URL(fileURLWithPath: runDirectory)
        let log = try openLog()
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            self?.coreExited(finished)
        }
        try process.run()
        self.process = process
    }

    private func coreExited(_ finished: Process) {
        lock.lock()
        guard finished === process, wantsRunning, request != nil, restarts < maxRestarts else {
            if finished === process { process = nil }
            lock.unlock()
            return
        }
        restarts += 1
        let delay = restartDelay
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.wantsRunning, self.process === finished else { return }
            try? self.launchLocked()
        }
    }

    private func terminateLocked() {
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    // MARK: - Files

    private func prepareDirectory() throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: runDirectory, isDirectory: &isDirectory) {
            // Refuse a symlink or a file planted in place of the folder.
            let attributes = try manager.attributesOfItem(atPath: runDirectory)
            guard isDirectory.boolValue, attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw SocketError.system("run directory", EEXIST)
            }
        } else {
            try manager.createDirectory(atPath: runDirectory, withIntermediateDirectories: true)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runDirectory)
    }

    /// Replaces the file with one readable only by its owner.
    private func writeSecure(_ data: Data, to path: String) throws {
        let manager = FileManager.default
        try? manager.removeItem(atPath: path)
        guard manager.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SocketError.system("write \(URL(fileURLWithPath: path).lastPathComponent)", errno)
        }
    }

    private func openLog() throws -> FileHandle {
        try writeSecure(Data(), to: logPath)
        guard let handle = FileHandle(forWritingAtPath: logPath) else {
            throw SocketError.system("open log", errno)
        }
        return handle
    }
}
