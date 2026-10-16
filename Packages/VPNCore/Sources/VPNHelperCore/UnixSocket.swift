import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case system(String, Int32)
    case pathTooLong
    case tooLarge
    case closed

    public var description: String {
        switch self {
        case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
        case .pathTooLong: "socket path is too long"
        case .tooLarge: "message is too large"
        case .closed: "connection closed"
        }
    }

    /// The helper is not installed or not running.
    public var isNotRunning: Bool {
        if case .system("connect", let code) = self { return code == ENOENT || code == ECONNREFUSED }
        return false
    }
}

#if os(Linux)
private let systemConnect = Glibc.connect
#else
private let systemConnect = Darwin.connect
#endif

/// Minimal Unix-domain stream sockets with newline-delimited messages.
/// Works on macOS and Linux so the helper can be tested in CI and in the cloud.
public enum UnixSocket {
    static var streamType: Int32 {
        #if os(Linux)
        return Int32(SOCK_STREAM.rawValue)
        #else
        return SOCK_STREAM
        #endif
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return address
    }

    /// Listening socket at `path`, mode 0600, owned by `ownerUID` when given.
    public static func makeListener(path: String, ownerUID: uid_t?) throws -> Int32 {
        unlink(path)
        let descriptor = socket(AF_UNIX, streamType, 0)
        guard descriptor >= 0 else { throw SocketError.system("socket", errno) }
        var address = try address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("bind", code)
        }
        chmod(path, 0o600)
        if let ownerUID {
            chown(path, ownerUID, gid_t.max)
        }
        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("listen", code)
        }
        return descriptor
    }

    public static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, streamType, 0)
        guard descriptor >= 0 else { throw SocketError.system("socket", errno) }
        var address = try address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("connect", code)
        }
        return descriptor
    }

    public static func setTimeout(_ descriptor: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    /// uid of the process on the other end of a connected socket.
    public static func peerUID(_ descriptor: Int32) -> uid_t? {
        #if os(Linux)
        // struct ucred { pid_t pid; uid_t uid; gid_t gid; }, SO_PEERCRED = 17.
        var credentials = [Int32](repeating: 0, count: 3)
        var size = socklen_t(MemoryLayout<Int32>.size * 3)
        guard getsockopt(descriptor, SOL_SOCKET, 17, &credentials, &size) == 0 else { return nil }
        return uid_t(bitPattern: credentials[1])
        #else
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else { return nil }
        return uid
        #endif
    }

    /// Reads up to the first newline (or the end of the stream).
    public static func readMessage(_ descriptor: Int32, maxSize: Int) throws -> Data {
        var message = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("read", errno)
            }
            if count == 0 { break }
            message.append(contentsOf: buffer[0..<count])
            if message.count > maxSize { throw SocketError.tooLarge }
            if let newline = message.firstIndex(of: 0x0A) {
                return message.prefix(upTo: newline)
            }
        }
        guard !message.isEmpty else { throw SocketError.closed }
        return message
    }

    public static func writeMessage(_ descriptor: Int32, _ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system("write", errno)
                }
                offset += written
            }
        }
    }
}
