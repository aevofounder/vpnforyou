import Foundation
import VPNCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        let config = try MihomoConfigBuilder.configData(for: request, appsRulesPath: appsPath)
        let apps = Data(MihomoConfigBuilder.appsRules(paths: request.appPaths).utf8)

        lock.lock()
        defer { lock.unlock() }
        terminateLocked()
        try prepareDirectory()
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
    }

    /// Rewrites the per-app rules; mihomo reloads the file by itself.
    public func setApps(_ paths: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var current = request else { return }
        current.appPaths = paths
        try MihomoConfigBuilder.validate(current)
        try writeSecure(Data(MihomoConfigBuilder.appsRules(paths: paths).utf8), to: appsPath)
        request = current
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
