import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredShortcut: AppShortcut?

    func register(_ shortcut: AppShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        if hotKey != nil && registeredShortcut?.hasSameKeys(as: shortcut) == true { return true }
        if handler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            let installResult = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    Task { @MainActor in
                        AppController.shared.togglePanel()
                    }
                    return noErr
                },
                1,
                &eventType,
                nil,
                &handler
            )
            guard installResult == noErr else { return false }
        }

        unregister()
        let identifier = EventHotKeyID(signature: 0x4353_4846, id: 1)
        let result = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        registeredShortcut = result == noErr ? shortcut : nil
        return result == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredShortcut = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
