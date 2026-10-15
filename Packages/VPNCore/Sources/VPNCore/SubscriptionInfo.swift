import Foundation

/// Traffic and expiry from the `subscription-userinfo` response header:
/// `upload=…; download=…; total=…; expire=…` (bytes and a Unix timestamp).
public struct SubscriptionUsage: Codable, Equatable, Sendable {
    public var upload: Int64
    public var download: Int64
    /// nil means unlimited.
    public var total: Int64?
    /// nil means no expiry.
    public var expiresAt: Date?

    public init(upload: Int64, download: Int64, total: Int64?, expiresAt: Date?) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expiresAt = expiresAt
    }

    public init?(header: String) {
        var values: [String: Int64] = [:]
        for part in header.split(separator: ";") {
            let keyValue = part.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            let key = keyValue[0].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = keyValue[1].trimmingCharacters(in: .whitespaces)
            if let value = Int64(raw) ?? Double(raw).flatMap({ Int64(exactly: $0.rounded()) }) {
                values[key] = value
            }
        }
        guard !values.isEmpty else { return nil }
        upload = max(0, values["upload"] ?? 0)
        download = max(0, values["download"] ?? 0)
        total = values["total"].flatMap { $0 > 0 ? $0 : nil }
        expiresAt = values["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
    }

    public var used: Int64 { upload + download }

    /// Share of traffic used, 0…1; nil when unlimited.
    public var fractionUsed: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }

    /// Whole days left, rounded up; nil when there is no expiry.
    public func daysLeft(now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        let seconds = expiresAt.timeIntervalSince(now)
        return seconds <= 0 ? 0 : Int((seconds / 86_400).rounded(.up))
    }
}

/// Other headers that subscription panels send.
public enum SubscriptionHeaders {
    /// `profile-title`, either plain text or `base64:…`.
    public static func title(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("base64:") {
            value = SubscriptionDecoder.base64Text(String(value.dropFirst("base64:".count))) ?? ""
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `profile-update-interval` in hours.
    public static func updateIntervalHours(_ raw: String?) -> Int? {
        guard let raw, let hours = Int(raw.trimmingCharacters(in: .whitespaces)), hours > 0 else { return nil }
        return min(hours, 24 * 7)
    }
}
