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
            session: CoreSession.random(controllerPort: 29_190, mixedPort: 29_191)
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
        bad.session.controllerSecret = "x"
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
}
