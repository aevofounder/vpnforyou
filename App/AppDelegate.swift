import AppKit
import VPNCore
import VPNHelperCore

/// Stops the VPN core when the app quits: the core's secrets live only in
/// this process, so a core left running could not be controlled anymore.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = try? HelperClient.send(HelperRequest(command: .stop), timeoutSeconds: 5)
        return .terminateNow
    }
}
