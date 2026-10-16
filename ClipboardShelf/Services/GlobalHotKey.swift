import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() -> Bool {
        if hotKey != nil { return true }
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

        let identifier = EventHotKeyID(signature: 0x4353_4846, id: 1)
        let result = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        return result == noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
