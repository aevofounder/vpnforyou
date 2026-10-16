import Carbon.HIToolbox
import Foundation

/// ⌥⌘V anywhere in macOS turns the VPN on or off (Carbon hot key:
/// needs no Accessibility permission).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let enabledKey = "general.hotKey"

    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func apply() {
        Self.isEnabled ? register() : unregister()
    }

    private func register() {
        guard hotKey == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
            }
            return noErr
        }, 1, &eventType, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5650_4E59), id: 1) // "VPNY"
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
