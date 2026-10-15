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

    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: rule.template
            )
        }
        return result
    }
}
