import Foundation

/// Masks secrets before text goes to logs or the clipboard:
/// VPN share links, UUIDs and IPv4 addresses.
public enum LogRedactor {
    private static let rules: [(regex: NSRegularExpression, template: String)] = [
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b(vless|vmess|trojan|ss|ssr|hysteria2?|hy2|tuic|anytls|wireguard|wg)://\S+"#
            ),
            "$1://[скрыто]"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#
            ),
            "[uuid]"
        ),
        (
            try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
            "[ip]"
        ),
    ]

    /// Candidates for IPv6 addresses; checked further in `looksLikeIPv6`.
    private static let ipv6Candidate = try! NSRegularExpression(pattern: #"(?<![\w:])[0-9A-Fa-f:]{3,}(?![\w:])"#)

    /// - Parameter hosts: server addresses to hide as well (from the user's profiles).
    public static func redact(_ text: String, hosts: [String] = []) -> String {
        var result = text
        // Longest first, so "vpn.example.com" is not cut by "example.com".
        for host in Set(hosts).filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: host, with: "[сервер]", options: .caseInsensitive)
        }
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: rule.template
            )
        }
        let matches = ipv6Candidate.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result), looksLikeIPv6(result[range]) else { continue }
            result.replaceSubrange(range, with: "[ip6]")
        }
        return result
    }

    /// "2001:db8::1" or a full address, but not a clock time like "21:49:03".
    static func looksLikeIPv6(_ token: Substring) -> Bool {
        let colons = token.filter { $0 == ":" }.count
        return token.contains("::") ? colons >= 2 && token.count >= 3 : colons >= 4
    }
}
