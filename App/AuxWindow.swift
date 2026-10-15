import AppKit
import SwiftUI

/// Regular windows (Activity) for a menu bar app: opened by hand with
/// NSHostingController, so nothing opens on launch and a closed window
/// stops its polling.
@MainActor
enum AuxWindow {
    private static var windows: [String: NSWindow] = [:]
    private static var observers: [String: NSObjectProtocol] = [:]

    static func show<Content: View>(id: String, title: String, size: NSSize, content: () -> Content) {
        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("VPNforYou.\(id)")
        windows[id] = window
        observers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                windows[id]?.contentViewController = nil
                windows[id] = nil
                if let observer = observers.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
