import Foundation

/// Turns a subscription body (or pasted text) into servers.
///
/// Supported formats:
/// - share links, one per line;
/// - the same list in base64 (standard or URL-safe, with or without padding);
/// - Xray JSON: an array of configs or a single config.
public enum SubscriptionDecoder {
    public static func decode(_ data: Data) throws -> ParsedSubscription {
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.unrecognizedFormat }
        return try decode(text: text)
    }

    public static func decode(text raw: String) throws -> ParsedSubscription {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.emptySubscription }
        return try decode(trimmed: text, allowBase64: true)
    }

    private static func decode(trimmed text: String, allowBase64: Bool) throws -> ParsedSubscription {
        if text.hasPrefix("[") || text.hasPrefix("{"),
           let parsed = try? XrayJSONParser.parse(Data(text.utf8)) {
            return parsed
        }
        if text.contains("://") {
            return parseLinks(text)
        }
        if text.hasPrefix("proxies:") || text.contains("\nproxies:") {
            throw ImportError.unsupportedFormat("Clash YAML")
        }
        if allowBase64, let decoded = base64Text(text) {
            return try decode(trimmed: decoded.trimmingCharacters(in: .whitespacesAndNewlines), allowBase64: false)
        }
        throw ImportError.unrecognizedFormat
    }

    /// Parses share links, one per line. Blank lines and comments are ignored;
    /// broken or unsupported links end up in `skipped`.
    public static func parseLinks(_ text: String) -> ParsedSubscription {
        var result = ParsedSubscription()
        for line in text.components(separatedBy: .newlines) {
            let link = line.trimmingCharacters(in: .whitespaces)
            if link.isEmpty || link.hasPrefix("#") || link.hasPrefix("//") { continue }
            do {
                result.add(try ShareLinkParser.parse(link))
            } catch let error as ImportError {
                result.skipped.append(SkippedEntry(name: ShareLinkParser.scheme(of: link), reason: error.message))
            } catch {
                result.skipped.append(SkippedEntry(name: ShareLinkParser.scheme(of: link), reason: ImportError.unrecognizedFormat.message))
            }
        }
        return result
    }

    /// Lenient base64: ignores whitespace, accepts the URL-safe alphabet and missing padding.
    static func base64Text(_ text: String) -> String? {
        var compact = text.filter { !$0.isWhitespace }
        compact = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = compact.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { compact += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: compact), let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }
}
