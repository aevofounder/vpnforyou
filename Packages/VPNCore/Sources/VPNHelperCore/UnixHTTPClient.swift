import Foundation
import VPNCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal HTTP/1.1 client over a Unix socket, for the core's API socket.
/// One request per connection (`Connection: close`); handles Content-Length,
/// chunked bodies and read-until-close.
public enum UnixHTTPClient {
    public struct Response: Equatable, Sendable {
        public var status: Int
        public var body: Data
    }

    public enum HTTPError: Error, Equatable {
        case badResponse
        case tooLarge
    }

    public static let maxResponseSize = 8 * 1024 * 1024

    public static func send(_ request: MihomoRequest, socketPath: String, timeoutSeconds: Int = 10) throws -> Response {
        let descriptor = try UnixSocket.connect(path: socketPath)
        defer { close(descriptor) }
        UnixSocket.setTimeout(descriptor, seconds: timeoutSeconds)

        var head = "\(request.method) \(request.path) HTTP/1.1\r\nHost: mihomo\r\nConnection: close\r\n"
        if let body = request.body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if request.method != "GET" {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var outgoing = Data(head.utf8)
        if let body = request.body { outgoing.append(body) }
        try writeAll(descriptor, outgoing)

        var incoming = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("read", errno)
            }
            if count == 0 { break }
            incoming.append(contentsOf: buffer[0..<count])
            guard incoming.count <= maxResponseSize else { throw HTTPError.tooLarge }
            if case .some(.some) = try? parse(incoming) { break }
        }
        guard let response = try parse(incoming, atEOF: true) else { throw HTTPError.badResponse }
        return response
    }

    /// Parses a full response; nil while more bytes are needed.
    static func parse(_ data: Data, atEOF: Bool = false) throws -> Response? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            if atEOF { throw HTTPError.badResponse }
            return nil
        }
        let headerText = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else {
            throw HTTPError.badResponse
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = Data(data[headerEnd.upperBound...])

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = try decodeChunked(body) else {
                if atEOF { throw HTTPError.badResponse }
                return nil
            }
            return Response(status: status, body: decoded)
        }
        if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { throw HTTPError.badResponse }
            if body.count < length {
                if atEOF { throw HTTPError.badResponse }
                return nil
            }
            return Response(status: status, body: Data(body.prefix(length)))
        }
        if status == 204 || status == 304 || (100..<200).contains(status) {
            return Response(status: status, body: Data())
        }
        return atEOF ? Response(status: status, body: body) : nil
    }

    /// Joins chunks; nil if the terminating zero-size chunk has not arrived yet.
    static func decodeChunked(_ data: Data) throws -> Data? {
        var result = Data()
        var index = data.startIndex
        let lineEnd = Data("\r\n".utf8)
        while true {
            guard let sizeEnd = data.range(of: lineEnd, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<sizeEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw HTTPError.badResponse }
            let chunkStart = sizeEnd.upperBound
            if size == 0 { return result }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            result.append(data[chunkStart..<chunkEnd])
            guard result.count <= maxResponseSize else { throw HTTPError.tooLarge }
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
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
