import Foundation
import VPNCore

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    /// Traffic rate from the core, e.g. "2,4 МБ/с".
    static func rate(_ bytesPerSecond: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytesPerSecond), countStyle: .decimal) + "/с"
    }

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
            parts.append("\(bytes(usage.used)) из \(bytes(total))")
        } else {
            parts.append("\(bytes(usage.used)) · без лимита")
        }
        if let days = usage.daysLeft() {
            parts.append(days == 0 ? "подписка закончилась" : "осталось " + plural(days, "день", "дня", "дней"))
        }
        return parts.joined(separator: " · ")
    }

    /// Russian plural forms: 1 день, 2 дня, 5 дней.
    static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1, mod100 != 11 {
            word = one
        } else if (2...4).contains(mod10), !(12...14).contains(mod100) {
            word = few
        } else {
            word = many
        }
        return "\(count) \(word)"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
