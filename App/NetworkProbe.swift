import Foundation
import Network
import VPNCore

/// URLSessions for IP checks and speed tests.
///
/// - `direct` ignores system proxies. While the VPN is on, the app's own
///   traffic still leaves directly: the core config sends the process
///   `VPNforYou` to DIRECT.
/// - `throughVPN` goes to the core's local proxy (127.0.0.1, random login
///   per connection), whose port the config routes to the VPN.
enum NetworkProbe {
    static func configuration(route: SpeedRoute, core: CoreSession?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        if route == .vpn, let core {
            configuration.connectionProxyDictionary = proxyDictionary(core)
        } else {
            configuration.connectionProxyDictionary = [:]
        }
        return configuration
    }

    static func proxyDictionary(_ core: CoreSession) -> [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: core.mixedPort,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: core.mixedPort,
            kCFProxyUsernameKey as String: core.mixedUser,
            kCFProxyPasswordKey as String: core.mixedPassword,
        ]
    }

    /// One IP lookup. Throws if the service is unreachable or answers nonsense.
    static func lookupIP(service: IPService, route: SpeedRoute, core: CoreSession?) async throws -> IPInfo {
        let delegate = ProxyAuthDelegate(core: route == .vpn ? core : nil)
        let session = URLSession(configuration: configuration(route: route, core: core), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: service.request())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw http.statusCode == 407 || http.statusCode == 403 ? ProbeError.proxyRefused : URLError(.badServerResponse)
        }
        return try service.parse(data.prefix(64 * 1024))
    }

    /// Time of a TCP handshake with the server, in milliseconds. Used only while
    /// the VPN is off: with TUN on, the core would answer the handshake itself.
    static func tcpPing(host: String, port: Int, timeout: TimeInterval = 3) async -> Int? {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else { return nil }
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let started = Date()
        let box = OnceBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                box.set(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.resume(Int(Date().timeIntervalSince(started) * 1_000))
                        connection.cancel()
                    case .failed, .waiting:
                        box.resume(nil)
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    box.resume(nil)
                    connection.cancel()
                }
            }
        } onCancel: {
            box.resume(nil)
            connection.cancel()
        }
    }

    enum ProbeError: LocalizedError {
        case proxyRefused

        var errorDescription: String? { "локальный прокси ядра не пустил запрос" }
    }
}

/// Resumes a continuation exactly once, whichever callback comes first.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int?, Never>?
    private var pending: Int??

    func set(_ continuation: CheckedContinuation<Int?, Never>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Int?) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            pending = .some(value)
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        if pending == nil { pending = .some(value) }
        lock.unlock()
    }
}

/// Answers the core's proxy login challenge (407) with this connection's login.
final class ProxyAuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let core: CoreSession?

    init(core: CoreSession?) {
        self.core = core
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.answer(challenge, core: core)
    }

    static func answer(_ challenge: URLAuthenticationChallenge,
                       core: CoreSession?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.isProxy() else { return (.performDefaultHandling, nil) }
        guard let core, challenge.previousFailureCount == 0 else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: core.mixedUser, password: core.mixedPassword, persistence: .forSession))
    }
}
