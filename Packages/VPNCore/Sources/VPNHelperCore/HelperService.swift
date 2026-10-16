import Foundation
import VPNCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Turns requests into actions on the core supervisor.
public struct HelperHandler: Sendable {
    public let supervisor: CoreSupervisor

    public init(supervisor: CoreSupervisor) {
        self.supervisor = supervisor
    }

    public func handle(_ request: HelperRequest) -> HelperResponse {
        do {
            switch request.command {
            case .hello:
                break
            case .status:
                return HelperResponse(ok: true, helperVersion: HelperProtocol.version,
                                      running: supervisor.isRunning, apiReady: supervisor.apiReady)
            case .select:
                guard let target = request.target else { return .failure("select: нет сервера") }
                try supervisor.select(target)
            case .delay:
                guard let target = request.target else { return .failure("delay: нет сервера") }
                return HelperResponse(ok: true, helperVersion: HelperProtocol.version, running: true,
                                      delay: try supervisor.delay(target))
            case .connections:
                return HelperResponse(ok: true, helperVersion: HelperProtocol.version, running: true,
                                      connections: try supervisor.connections())
            case .traffic:
                return HelperResponse(ok: true, helperVersion: HelperProtocol.version, running: true,
                                      traffic: try supervisor.trafficTotals())
            case .start:
                guard let start = request.start else { return .failure("start: нет параметров") }
                try supervisor.start(start)
            case .stop:
                supervisor.stop()
            case .setApps:
                guard let apps = request.apps else { return .failure("setApps: нет списка") }
                try supervisor.setApps(apps.paths)
            case .logs:
                return HelperResponse(ok: true, helperVersion: HelperProtocol.version,
                                      running: supervisor.isRunning, logs: supervisor.logTail())
            }
            return HelperResponse(ok: true, helperVersion: HelperProtocol.version, running: supervisor.isRunning)
        } catch let error as CoreConfigError {
            return .failure(error.message)
        } catch let error as HelperError {
            var response = HelperResponse.failure(error.message)
            response.running = supervisor.isRunning
            return response
        } catch {
            return .failure(String(describing: error))
        }
    }
}

/// Accepts connections on the helper socket. Only `allowedUID` (and root) may talk to it.
public final class HelperServer: @unchecked Sendable {
    public let socketPath: String
    public let allowedUID: uid_t
    private let handler: HelperHandler
    private var listener: Int32 = -1

    public init(socketPath: String, allowedUID: uid_t, handler: HelperHandler) {
        self.socketPath = socketPath
        self.allowedUID = allowedUID
        self.handler = handler
    }

    /// Opens the socket. Call before `serve()`.
    public func open() throws {
        listener = try UnixSocket.makeListener(path: socketPath, ownerUID: allowedUID)
    }

    /// Accept loop; each client is served on its own queue item, so a slow
    /// latency check does not hold up the others. Blocks forever.
    public func serve() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                usleep(100_000)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                handleClient(client)
                close(client)
            }
        }
    }

    func handleClient(_ client: Int32) {
        UnixSocket.setTimeout(client, seconds: 10)
        let response: HelperResponse
        if let uid = UnixSocket.peerUID(client), uid == allowedUID || uid == 0 {
            do {
                let data = try UnixSocket.readMessage(client, maxSize: HelperProtocol.maxMessageSize)
                let request = try JSONDecoder().decode(HelperRequest.self, from: data)
                response = handler.handle(request)
            } catch {
                response = .failure("Неверный запрос")
            }
        } else {
            response = .failure("Нет доступа")
        }
        if let data = try? JSONEncoder().encode(response) {
            try? UnixSocket.writeMessage(client, data)
        }
    }
}

/// Command-line options of the helper executable.
public struct HelperArguments: Equatable {
    public var allowedUID: uid_t
    public var socketPath = HelperProtocol.socketPath
    public var corePath = HelperProtocol.corePath
    public var runDirectory = HelperProtocol.runDirectory

    /// `--allowed-uid N [--socket P] [--core P] [--run-dir P]`
    public static func parse(_ arguments: [String]) -> HelperArguments? {
        var values: [String: String] = [:]
        var index = 1
        while index + 1 < arguments.count {
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let uidText = values["--allowed-uid"], let uid = uid_t(uidText) else { return nil }
        var parsed = HelperArguments(allowedUID: uid)
        if let socket = values["--socket"] { parsed.socketPath = socket }
        if let core = values["--core"] { parsed.corePath = core }
        if let run = values["--run-dir"] { parsed.runDirectory = run }
        return parsed
    }
}
