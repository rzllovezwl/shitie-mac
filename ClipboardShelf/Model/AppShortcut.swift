import AppKit
import Carbon

/// A physical key and its modifiers. The label is saved only for display;
/// matching and global registration always use the key code.
struct AppShortcut: Codable, Equatable {
    static let defaultOpenPanel = AppShortcut(
        keyCode: UInt16(kVK_ANSI_V), modifiers: [.command, .shift], keyLabel: "V"
    )
    static let defaultDeleteEntry = AppShortcut(
        keyCode: UInt16(kVK_Delete), modifiers: [.command], keyLabel: "⌫"
    )

    private static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    let keyCode: UInt16
    let modifierBits: UInt
    let keyLabel: String

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        modifierBits = modifiers.intersection(Self.relevantModifiers).rawValue
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent, requiresModifier: Bool = true) {
        guard let label = Self.label(for: event) else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, keyLabel: label)
        guard requiresModifier ? isValid : isValidForPanel else { return nil }
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierBits).intersection(Self.relevantModifiers)
    }

    var isValid: Bool {
        let held = modifiers
        return !held.intersection([.command, .control, .option]).isEmpty
            && isValidForPanel
    }

    var isValidForPanel: Bool {
        guard !keyLabel.isEmpty, keyLabel.count <= 4,
              !Self.modifierOnlyKeyCodes.contains(Int(keyCode)),
              keyCode != UInt16(kVK_Escape) else { return false }
        if !modifiers.isEmpty { return true }
        // Bare printable keys would intercept typing in the panel's search field.
        return Self.barePanelKeyCodes.contains(Int(keyCode))
    }

    var displayName: String {
        var label = ""
        if modifiers.contains(.command) { label += "⌘" }
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        return label + keyLabel
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode
            && self.modifiers == modifiers.intersection(Self.relevantModifiers)
    }

    func hasSameKeys(as other: AppShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    private static let modifierOnlyKeyCodes: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
        kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
        kVK_CapsLock, kVK_Function
    ]

    private static let barePanelKeyCodes: Set<Int> = [
        kVK_Delete, kVK_ForwardDelete, kVK_Return, kVK_ANSI_KeypadEnter,
        kVK_Tab, kVK_Space, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow,
        kVK_DownArrow, kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
        kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
    ]

    private static func label(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "空格"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            guard let text = event.charactersIgnoringModifiers,
                  !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                return nil
            }
            return text.uppercased()
        }
    }
}

enum AppShortcutAction: String, CaseIterable, Hashable {
    case openPanel, deleteEntry, focusSearch, previous, next
    case toggleDetail, paste, pastePlainText, copyOnly

    var title: String {
        switch self {
        case .openPanel: "唤起或收起面板"
        case .deleteEntry: "删除选中的记录"
        case .focusSearch: "搜索历史"
        case .previous: "上一条记录"
        case .next: "下一条记录"
        case .toggleDetail: "打开或关闭预览"
        case .paste: "按设置粘贴"
        case .pastePlainText: "纯文本粘贴"
        case .copyOnly: "仅复制"
        }
    }

    var preferenceKey: String {
        switch self {
        case .openPanel: AppShortcutPreference.openPanelKey
        case .deleteEntry: AppShortcutPreference.deleteEntryKey
        default: "panelShortcut.\(rawValue)"
        }
    }

    var defaultShortcut: AppShortcut {
        switch self {
        case .openPanel: .defaultOpenPanel
        case .deleteEntry: .defaultDeleteEntry
        case .focusSearch: AppShortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command], keyLabel: "F")
        case .previous: AppShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: [], keyLabel: "←")
        case .next: AppShortcut(keyCode: UInt16(kVK_RightArrow), modifiers: [], keyLabel: "→")
        case .toggleDetail: AppShortcut(keyCode: UInt16(kVK_Space), modifiers: [], keyLabel: "空格")
        case .paste: AppShortcut(keyCode: UInt16(kVK_Return), modifiers: [], keyLabel: "↩")
        case .pastePlainText: AppShortcut(keyCode: UInt16(kVK_Return), modifiers: [.option], keyLabel: "↩")
        case .copyOnly: AppShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command], keyLabel: "C")
        }
    }
}

enum AppShortcutPreference {
    static let openPanelKey = "openPanelShortcut"
    static let deleteEntryKey = "deleteEntryShortcut"

    static func load(_ key: String, fallback: AppShortcut, from defaults: UserDefaults = .standard,
                     requiresModifier: Bool = true) -> AppShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(AppShortcut.self, from: data),
              (requiresModifier ? shortcut.isValid : shortcut.isValidForPanel) else { return fallback }
        return shortcut
    }

    static func save(_ shortcut: AppShortcut, for key: String, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }
}
