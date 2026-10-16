import Foundation
import XCTest
import VPNCore
@testable import VPNHelperCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Uses a fake core (a shell script) instead of mihomo: no network, no TUN.
final class HelperTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vfy-helper-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fakeCore(_ body: String) throws -> String {
        let path = directory.appendingPathComponent("fake-core.sh").path
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
        return path
    }

    private func request(apps: [String] = ["/Applications/Telegram.app"]) throws -> CoreStartRequest {
        let server = try ShareLinkParser.parse(
            "vless://00000000-0000-0000-0000-000000000000@nl.example.com:443?security=reality&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA#NL"
        )
        return CoreStartRequest(
            servers: [server], groups: [], selectedID: server.id, routing: .onlySelected, appPaths: apps,
            session: CoreSession.random(mixedPort: 29_191)
        )
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    private func permissions(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testStartWritesPrivateFilesAndRunsCore() throws {
        let run = directory.appendingPathComponent("run").path
        let core = try fakeCore(#"echo "$@" > "$2/args.txt"; exec sleep 30"#)
        let supervisor = CoreSupervisor(corePath: core, runDirectory: run)

        try supervisor.start(try request())
        XCTAssertTrue(waitFor { FileManager.default.fileExists(atPath: run + "/args.txt") })
        XCTAssertTrue(supervisor.isRunning)

        let args = try String(contentsOfFile: run + "/args.txt", encoding: .utf8)
        XCTAssertEqual(args.trimmingCharacters(in: .whitespacesAndNewlines), "-d \(run) -f \(run)/config.json")
        XCTAssertEqual(try permissions(run), 0o700)
        XCTAssertEqual(try permissions(supervisor.configPath), 0o600)
        XCTAssertEqual(try permissions(supervisor.appsPath), 0o600)
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: supervisor.configPath))) as? [String: Any]
        XCTAssertEqual(config?["bind-address"] as? String, "127.0.0.1")

        try supervisor.setApps(["/Applications/Firefox.app"])
        let apps = try String(contentsOfFile: supervisor.appsPath, encoding: .utf8)
        XCTAssertTrue(apps.contains("Firefox\\.app/"))
        XCTAssertFalse(apps.contains("Telegram"))

        XCTAssertThrowsError(try supervisor.setApps(["not/absolute"]))

        supervisor.stop()
        XCTAssertFalse(supervisor.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: supervisor.configPath), "config with keys is removed on stop")
    }

    func testCrashedCoreIsRestartedAFewTimes() throws {
        let run = directory.appendingPathComponent("run").path
        let core = try fakeCore(#"echo x >> "$2/launches.txt"; exit 1"#)
        let supervisor = CoreSupervisor(corePath: core, runDirectory: run)
        supervisor.restartDelay = 0.05
        supervisor.maxRestarts = 2

        try supervisor.start(try request())
        let launches = run + "/launches.txt"
        XCTAssertTrue(waitFor { ((try? String(contentsOfFile: launches, encoding: .utf8))?.count ?? 0) >= 6 })
        usleep(500_000)
        // 1 start + 2 restarts, each line "x\n".
        XCTAssertEqual(try String(contentsOfFile: launches, encoding: .utf8).count, 6)
        supervisor.stop()
    }

    func testInvalidRequestIsRejectedBeforeAnythingRuns() throws {
        let run = directory.appendingPathComponent("run").path
        let supervisor = CoreSupervisor(corePath: try fakeCore("exec sleep 30"), runDirectory: run)
        var bad = try request()
        bad.session.mixedPassword = "x"
        let response = HelperHandler(supervisor: supervisor).handle(HelperRequest(command: .start, start: bad))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, CoreConfigError.invalidSecret.message)
        XCTAssertFalse(supervisor.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run))
    }

    func testSocketRoundTrip() throws {
        let socketPath = directory.appendingPathComponent("h.sock").path
        let supervisor = CoreSupervisor(corePath: try fakeCore("exec sleep 30"), runDirectory: directory.appendingPathComponent("run").path)
        let server = HelperServer(socketPath: socketPath, allowedUID: getuid(), handler: HelperHandler(supervisor: supervisor))
        try server.open()
        Thread.detachNewThread { server.serve() }

        XCTAssertEqual(try permissions(socketPath), 0o600)

        let hello = try HelperClient.send(HelperRequest(command: .hello), socketPath: socketPath)
        XCTAssertTrue(hello.ok)
        XCTAssertEqual(hello.helperVersion, HelperProtocol.version)
        XCTAssertEqual(hello.running, false)

        let started = try HelperClient.send(HelperRequest(command: .start, start: try request()), socketPath: socketPath)
        XCTAssertTrue(started.ok, started.error ?? "")
        XCTAssertEqual(started.running, true)

        let stopped = try HelperClient.send(HelperRequest(command: .stop), socketPath: socketPath)
        XCTAssertEqual(stopped.running, false)

        // Garbage gets an error, not a crash.
        let raw = try UnixSocket.connect(path: socketPath)
        try UnixSocket.writeMessage(raw, Data("not json".utf8))
        let reply = try JSONDecoder().decode(HelperResponse.self, from: UnixSocket.readMessage(raw, maxSize: 1 << 16))
        close(raw)
        XCTAssertFalse(reply.ok)
    }

    func testClientReportsMissingHelper() {
        XCTAssertThrowsError(try HelperClient.send(HelperRequest(command: .hello), socketPath: directory.appendingPathComponent("none.sock").path)) {
            XCTAssertTrue(($0 as? SocketError)?.isNotRunning == true)
        }
    }

    func testArguments() {
        XCTAssertNil(HelperArguments.parse(["helper"]))
        let parsed = HelperArguments.parse(["helper", "--allowed-uid", "501", "--socket", "/tmp/s"])
        XCTAssertEqual(parsed?.allowedUID, 501)
        XCTAssertEqual(parsed?.socketPath, "/tmp/s")
        XCTAssertEqual(parsed?.corePath, HelperProtocol.corePath)
    }

    // MARK: - Core API through the helper

    /// A tiny HTTP server on a Unix socket standing in for mihomo's API.
    private final class FakeAPI: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        let responses: [String: String]

        init(path: String, responses: [String: String]) throws {
            self.responses = responses
            let listener = try UnixSocket.makeListener(path: path, ownerUID: nil)
            Thread.detachNewThread { [self] in
                while true {
                    let client = accept(listener, nil, nil)
                    if client < 0 { return }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while data.range(of: Data("\r\n\r\n".utf8)) == nil {
                        let count = read(client, &buffer, buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer[0..<count])
                    }
                    let line = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                    lock.lock()
                    seen.append(line)
                    lock.unlock()
                    let key = line.split(separator: " ").prefix(2).joined(separator: " ")
                    let reply = responses[key] ?? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                    _ = reply.withCString { write(client, $0, strlen($0)) }
                    close(client)
                }
            }
        }

        var requests: [String] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    private static func json(_ body: String, status: String = "200 OK") -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    private static func chunked(_ body: String) -> String {
        let half = body.index(body.startIndex, offsetBy: body.count / 2)
        let parts = [String(body[..<half]), String(body[half...])]
        let chunks = parts.map { String($0.utf8.count, radix: 16) + "\r\n" + $0 + "\r\n" }.joined()
        return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunks + "0\r\n\r\n"
    }

    func testHTTPClientReadsLengthChunkedAndEmptyBodies() throws {
        let path = directory.appendingPathComponent("api.sock").path
        _ = try FakeAPI(path: path, responses: [
            "GET /version": Self.json(#"{"version":"test"}"#),
            "GET /connections": Self.chunked(#"{"downloadTotal":7,"uploadTotal":3,"connections":null}"#),
            "PUT /proxies/PROXY": "HTTP/1.1 204 No Content\r\n\r\n",
        ])
        let version = try UnixHTTPClient.send(.version, socketPath: path)
        XCTAssertEqual(version.status, 200)
        XCTAssertEqual(String(decoding: version.body, as: UTF8.self), #"{"version":"test"}"#)

        let connections = try UnixHTTPClient.send(.connections, socketPath: path)
        XCTAssertEqual(try ConnectionsSnapshot.parse(connections.body).downloadTotal, 7)

        XCTAssertEqual(try UnixHTTPClient.send(.select("s-1"), socketPath: path).status, 204)
        XCTAssertEqual(try UnixHTTPClient.send(MihomoRequest(path: "/nope"), socketPath: path).status, 404)
    }

    func testHTTPParserRejectsGarbage() {
        XCTAssertThrowsError(try UnixHTTPClient.parse(Data("hello".utf8), atEOF: true))
        XCTAssertThrowsError(try UnixHTTPClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort".utf8), atEOF: true))
        XCTAssertNil(try UnixHTTPClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort".utf8)))
    }

    func testAPICommandsOnlyReachKnownServers() throws {
        let run = directory.appendingPathComponent("run").path
        let supervisor = CoreSupervisor(corePath: try fakeCore("exec sleep 30"), runDirectory: run)
        let handler = HelperHandler(supervisor: supervisor)
        let start = try request()
        let id = start.selectedID

        // Nothing runs yet.
        XCTAssertEqual(handler.handle(HelperRequest(command: .select, target: id)).error, HelperError.notRunning.message)

        XCTAssertTrue(handler.handle(HelperRequest(command: .start, start: start)).ok)
        let api = try FakeAPI(path: supervisor.apiSocketPath, responses: [
            "GET /version": Self.json(#"{"version":"test"}"#),
            "PUT /proxies/PROXY": "HTTP/1.1 204 No Content\r\n\r\n",
            "GET /proxies/\(id)/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000": Self.json(#"{"delay":42}"#),
            "GET /connections": Self.json(#"{"downloadTotal":2048,"uploadTotal":512,"connections":[{"id":"c1","metadata":{"host":"www.example.com","processPath":"/Applications/Chat.app/Contents/MacOS/Chat"},"upload":1,"download":2,"chains":["PROXY"]}]}"#),
            "PUT /providers/rules/apps": "HTTP/1.1 204 No Content\r\n\r\n",
        ])

        let status = handler.handle(HelperRequest(command: .status))
        XCTAssertEqual(status.running, true)
        XCTAssertEqual(status.apiReady, true)

        XCTAssertTrue(handler.handle(HelperRequest(command: .select, target: id)).ok)
        XCTAssertEqual(handler.handle(HelperRequest(command: .delay, target: id)).delay, 42)
        XCTAssertEqual(handler.handle(HelperRequest(command: .traffic)).traffic, TrafficTotals(upload: 512, download: 2048))
        XCTAssertEqual(handler.handle(HelperRequest(command: .connections)).connections?.connections.first?.appName, "Chat")

        // Anything outside the running config is refused before it reaches the core.
        for target in ["s-unknown", "../configs", "PROXY", "DIRECT", ""] {
            let refused = handler.handle(HelperRequest(command: .select, target: target))
            XCTAssertFalse(refused.ok, target)
            XCTAssertEqual(refused.error, HelperError.unknownTarget.message)
            XCTAssertFalse(handler.handle(HelperRequest(command: .delay, target: target)).ok, target)
        }
        XCTAssertFalse(handler.handle(HelperRequest(command: .select)).ok)

        XCTAssertTrue(handler.handle(HelperRequest(command: .setApps, apps: AppsUpdate(paths: ["/Applications/Chat.app"]))).ok)
        XCTAssertTrue(waitFor { api.requests.contains("PUT /providers/rules/apps HTTP/1.1") })

        // The helper only ever sends these requests to the core.
        let allowed = ["GET /version ", "PUT /proxies/PROXY ", "GET /proxies/\(id)/delay?", "GET /connections ", "PUT /providers/rules/apps "]
        for line in api.requests {
            XCTAssertTrue(allowed.contains { line.hasPrefix($0) }, line)
        }
        supervisor.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: supervisor.apiSocketPath))
    }

    /// Talks to a real mihomo over its Unix-socket API when MIHOMO_BIN is set.
    /// TUN is switched off here so the test never touches the machine's routes.
    func testRealMihomoAPIOverUnixSocket() throws {
        guard let binary = ProcessInfo.processInfo.environment["MIHOMO_BIN"] else {
            throw XCTSkip("MIHOMO_BIN is not set")
        }
        let folder = directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let socket = folder.appendingPathComponent("api.sock").path
        let apps = folder.appendingPathComponent(MihomoConfigBuilder.appsFileName).path
        let start = try request()
        var config = try MihomoConfigBuilder.config(for: start, appsRulesPath: apps, apiSocketPath: socket)
        config["tun"] = ["enable": false]
        config["dns"] = ["enable": false]
        let configPath = folder.appendingPathComponent("config.json").path
        try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]).write(to: URL(fileURLWithPath: configPath))
        try Data(MihomoConfigBuilder.appsRules(paths: start.appPaths).utf8).write(to: URL(fileURLWithPath: apps))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-d", folder.path, "-f", configPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }

        XCTAssertTrue(waitFor({ (try? UnixHTTPClient.send(.version, socketPath: socket))?.status == 200 }, timeout: 10))
        XCTAssertEqual(try UnixHTTPClient.send(.select(start.selectedID), socketPath: socket).status, 204)
        XCTAssertEqual(try UnixHTTPClient.send(.reloadApps, socketPath: socket).status, 204)
        let snapshot = try ConnectionsSnapshot.parse(try UnixHTTPClient.send(.connections, socketPath: socket).body)
        XCTAssertEqual(snapshot.connections, [])
        // The fake server does not exist: an error answer, not a hang.
        let delay = try UnixHTTPClient.send(.delay(start.selectedID, timeoutMilliseconds: 1_000), socketPath: socket, timeoutSeconds: 5)
        XCTAssertNotEqual(delay.status, 200)
    }
}
