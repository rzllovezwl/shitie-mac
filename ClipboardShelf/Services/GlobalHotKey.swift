import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x4353_4846
    private let identifier: UInt32
    private let onPress: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredShortcut: AppShortcut?

    init(identifier: UInt32 = 1,
         onPress: @escaping @MainActor () -> Void) {
        self.identifier = identifier
        self.onPress = onPress
    }

    func register(_ shortcut: AppShortcut, allowsUnmodified: Bool = false,
                  allowsPrintableKey: Bool = false) -> Bool {
        guard shortcut.isValid ||
            (allowsUnmodified && shortcut.isValidForPanel) ||
            (allowsPrintableKey && shortcut.isValidForAnnotation) else { return false }
        return registerValidatedShortcut(shortcut)
    }

    func registerReturn() -> Bool {
        registerValidatedShortcut(AppShortcut(keyCode: UInt16(kVK_Return), modifiers: [], keyLabel: "↩"))
    }

    func registerEscape() -> Bool {
        registerValidatedShortcut(AppShortcut(keyCode: UInt16(kVK_Escape), modifiers: [], keyLabel: "Esc"))
    }

    private func registerValidatedShortcut(_ shortcut: AppShortcut) -> Bool {
        if hotKey != nil && registeredShortcut?.hasSameKeys(as: shortcut) == true { return true }
        if handler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            let installResult = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                    var triggered = EventHotKeyID(signature: 0, id: 0)
                    let result = GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &triggered
                    )
                    guard result == noErr else { return OSStatus(eventNotHandledErr) }
                    return MainActor.assumeIsolated {
                        let receiver = Unmanaged<GlobalHotKey>.fromOpaque(userData)
                            .takeUnretainedValue()
                        guard triggered.signature == GlobalHotKey.signature,
                              triggered.id == receiver.identifier else {
                            return OSStatus(eventNotHandledErr)
                        }
                        receiver.onPress()
                        return noErr
                    }
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &handler
            )
            guard installResult == noErr else { return false }
        }

        unregister()
        let identifier = EventHotKeyID(signature: Self.signature, id: identifier)
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
