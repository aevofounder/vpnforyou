import Foundation
import VPNCore

/// Installs and removes the privileged helper with the standard macOS
/// administrator password prompt (`do shell script … with administrator privileges`).
enum HelperInstaller {
    enum InstallError: LocalizedError {
        case cancelled
        case missingFiles
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "Установка отменена"
            case .missingFiles: "В сборке нет помощника или ядра mihomo. Скачайте сборку из GitHub Actions."
            case .failed(let detail): "Не удалось установить помощника: \(detail)"
            }
        }
    }

    static var executablesDirectory: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path
    }

    static func install() async throws {
        let directory = executablesDirectory
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: directory + "/" + HelperProtocol.bundledHelperName),
              manager.isExecutableFile(atPath: directory + "/" + HelperProtocol.bundledCoreName)
        else { throw InstallError.missingFiles }

        let plist = manager.temporaryDirectory.appendingPathComponent("vpnforyou-helper-\(UUID().uuidString).plist")
        try HelperProtocol.launchdPlist(allowedUID: getuid()).write(to: plist)
        defer { try? manager.removeItem(at: plist) }

        let shell = HelperInstallScript.install(executables: directory, plistFile: plist.path)
        try await runAsAdministrator(
            shell,
            prompt: "VPNforYou устанавливает помощника, который включает VPN. Пароль нужен один раз."
        )
    }

    static func uninstall() async throws {
        try await runAsAdministrator(HelperInstallScript.uninstall(), prompt: "VPNforYou удаляет своего помощника.")
    }

    private static func runAsAdministrator(_ shell: String, prompt: String) async throws {
        let source = HelperInstallScript.appleScript(shell: shell, prompt: prompt)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                    return
                }
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if message.contains("-128") {
                    continuation.resume(throwing: InstallError.cancelled)
                } else {
                    continuation.resume(throwing: InstallError.failed(LogRedactor.redact(message.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: InstallError.failed(error.localizedDescription))
            }
        }
    }
}
