import Foundation
import VPNCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Talks to the privileged helper. Blocking: call it off the main thread.
public enum HelperClient {
    public static func send(
        _ request: HelperRequest,
        socketPath: String = HelperProtocol.socketPath,
        timeoutSeconds: Int = 20
    ) throws -> HelperResponse {
        let descriptor = try UnixSocket.connect(path: socketPath)
        defer { close(descriptor) }
        UnixSocket.setTimeout(descriptor, seconds: timeoutSeconds)
        try UnixSocket.writeMessage(descriptor, JSONEncoder().encode(request))
        let reply = try UnixSocket.readMessage(descriptor, maxSize: HelperProtocol.maxMessageSize)
        return try JSONDecoder().decode(HelperResponse.self, from: reply)
    }
}
