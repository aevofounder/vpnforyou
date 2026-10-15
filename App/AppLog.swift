import AppKit
import Foundation
import VPNCore

/// The app's own event log: in memory only, last 300 lines, secrets masked
/// on the way in. Used for "Скопировать логи без секретов".
@MainActor
enum AppLog {
    private static var lines: [String] = []
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func add(_ message: String) {
        lines.append("\(formatter.string(from: Date())) \(LogRedactor.redact(message))")
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
    }

    static var recent: [String] { lines }
}

/// A plain-text report for bug reports. Server addresses, keys, UUIDs and
/// IPs are masked; the user sees it in the clipboard before sharing.
@MainActor
enum DiagnosticReport {
    static func build(model: AppModel, connection: ConnectionManager, routing: RoutingStore) async -> String {
        let helperLogs = await connection.helperLogs()
        let hosts = model.allServers.map(\.host)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var protocols: [String: Int] = [:]
        for server in model.allServers { protocols[server.summary, default: 0] += 1 }

        var report: [String] = [
            "VPNforYou \(Bundle.main.appVersion)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(architecture)",
            "Помощник: \(connection.helperState)",
            "Состояние: \(describe(connection.state))",
            "Режим: \(routing.mode.rawValue), программ в списке: \(routing.paths.count)",
            "Подписок: \(model.profiles.count), серверов: \(model.allServers.count), групп: \(model.allGroups.count)",
            "Протоколы: " + protocols.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "),
            "",
            "== Приложение ==",
        ]
        report += AppLog.recent
        report += ["", "== Ядро (через помощника) =="]
        report += helperLogs.isEmpty ? ["(пусто)"] : helperLogs
        return LogRedactor.redact(report.joined(separator: "\n"), hosts: hosts)
    }

    static func copy(model: AppModel, connection: ConnectionManager, routing: RoutingStore) async {
        let text = await build(model: model, connection: connection, routing: routing)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppLog.add("Логи скопированы")
    }

    private static var architecture: String {
        #if arch(arm64)
        "Apple Silicon"
        #else
        "Intel"
        #endif
    }

    private static func describe(_ state: ConnectionManager.State) -> String {
        switch state {
        case .disconnected: "выключено"
        case .connecting: "подключение"
        case .connected: "подключено"
        case .disconnecting: "отключение"
        case .failed(let message): "ошибка: \(message)"
        }
    }
}
