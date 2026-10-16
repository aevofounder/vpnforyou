import AppKit
import Sparkle

/// Updates through Sparkle from the beta channel (GitHub release "beta").
/// Every update is checked against the EdDSA public key in Info.plist;
/// builds without that key (local ones) never update themselves.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// Set right before Sparkle relaunches the app, so a VPN that was on comes back on.
    static let reconnectKey = "updates.reconnectAfterRelaunch"

    private var controller: SPUStandardUpdaterController?
    /// Asked before a relaunch: is the VPN on right now?
    var isVPNConnected: () -> Bool = { false }

    var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        return key.count == 44 && feed.hasPrefix("https://")
    }

    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        AppLog.add("Обновления: проверка включена")
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            UserDefaults.standard.set(isVPNConnected(), forKey: Self.reconnectKey)
            AppLog.add("Обновление установлено, перезапуск")
        }
    }

    /// True once after an update relaunch if the VPN was on before it.
    static func takeReconnectFlag() -> Bool {
        let defaults = UserDefaults.standard
        let value = defaults.bool(forKey: reconnectKey)
        defaults.removeObject(forKey: reconnectKey)
        return value
    }
}
