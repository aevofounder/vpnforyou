import Foundation
import VPNCore

/// HTTP calls to the local mihomo API (127.0.0.1 + secret).
/// Its own session ignores any system proxy.
struct MihomoClient: Sendable {
    let api: MihomoAPI
    private let session: URLSession

    init(session coreSession: CoreSession) {
        api = MihomoAPI(session: coreSession)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    func isAlive() async -> Bool {
        guard let result = try? await session.data(for: api.version) else { return false }
        return (result.1 as? HTTPURLResponse)?.statusCode == 200
    }

    func select(_ id: String) async throws {
        let (_, response) = try await session.data(for: api.select(id))
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
    }

    /// Latency in milliseconds, nil on timeout or error.
    func delay(_ name: String) async -> Int? {
        guard let result = try? await session.data(for: api.delay(name)) else { return nil }
        return (try? JSONDecoder().decode(DelayResult.self, from: result.0))?.delay
    }

    func connections() async throws -> ConnectionsSnapshot {
        let (data, _) = try await session.data(for: api.connections)
        return try ConnectionsSnapshot.parse(data)
    }

    func reloadApps() async {
        _ = try? await session.data(for: api.reloadApps)
    }

    /// `/traffic` streams one JSON line per second until cancelled.
    func traffic() -> AsyncThrowingStream<TrafficSample, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = api.traffic
                    request.timeoutInterval = 3_600
                    let (bytes, _) = try await session.bytes(for: request)
                    for try await line in bytes.lines {
                        if let sample = TrafficSample.parse(line: line) { continuation.yield(sample) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
