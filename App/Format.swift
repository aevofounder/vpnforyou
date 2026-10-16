import Foundation
import VPNCore

enum Format {
    /// "29,9 МБ"; never "Zero KB".
    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    /// Traffic rate from the core, e.g. "2,4 МБ/с".
    static func rate(_ bytesPerSecond: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, bytesPerSecond)) + "/с"
    }

    /// Subscription traffic in decimal GB, the way sellers count it: "102,5 ГБ из 1 000 ГБ".
    static func traffic(_ value: Int64) -> String {
        trafficFormatter.string(fromByteCount: max(0, value))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let trafficFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    /// Speed test number without the unit: "95,3", "940", "0,8".
    static func mbps(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value >= 100 ? 0 : 1
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    static func milliseconds(_ value: Double) -> String {
        "\(Int(value.rounded())) мс"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "102,5 ГБ из 1 000 ГБ · осталось 24 дня".
    static func usage(_ usage: SubscriptionUsage) -> String {
        var parts: [String] = []
        if let total = usage.total {
            parts.append("\(traffic(usage.used)) из \(traffic(total))")
        } else {
            parts.append("\(traffic(usage.used)) · без лимита")
        }
        if let days = usage.daysLeft() {
            parts.append(days == 0 ? "подписка закончилась" : "осталось " + plural(days, "день", "дня", "дней"))
        }
        return parts.joined(separator: " · ")
    }

    /// Russian plural forms: 1 день, 2 дня, 5 дней.
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(count) \(word(count, one, few, many))"
    }

    /// Just the word in the right form: день, дня, дней.
    static func word(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1, mod100 != 11 { return one }
        if (2...4).contains(mod10), !(12...14).contains(mod100) { return few }
        return many
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
