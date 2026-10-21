import AppKit
import Carbon

private enum ShortcutTestError: Error { case failed(String) }

@main
struct ShortcutSmoke {
    static func main() throws {
        try check(AppShortcut.defaultOpenPanel.displayName == "⌘⇧V", "默认唤起键显示错误")
        try check(AppShortcut.defaultDeleteEntry.displayName == "⌘⌫", "默认删除键显示错误")
        try check(AppShortcut.defaultDeleteEntry.carbonModifiers == UInt32(cmdKey), "Carbon 修饰键转换错误")
        try check(AppShortcut.defaultDeleteEntry.matches(
            keyCode: UInt16(kVK_Delete), modifiers: [.command, .capsLock]
        ), "大写锁定不应影响快捷键")

        let customEvent = try event(keyCode: kVK_ANSI_K, modifiers: [.control, .option], text: "k")
        guard let custom = AppShortcut(event: customEvent) else {
            throw ShortcutTestError.failed("无法录制有效的自定义组合键")
        }
        try check(custom.displayName == "⌃⌥K", "自定义组合键显示错误")
        try check(custom.hasSameKeys(as: AppShortcut(
            keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option], keyLabel: "不同键盘布局"
        )), "同一物理按键不能因显示文本不同而逃过冲突检查")
        try check(custom.carbonModifiers == UInt32(controlKey | optionKey), "自定义 Carbon 修饰键错误")
        try check(AppShortcut(event: try event(keyCode: kVK_ANSI_K, modifiers: [], text: "k")) == nil,
                  "不能录制无修饰键的按键")
        try check(AppShortcut(event: try event(keyCode: kVK_ANSI_F, modifiers: [.command], text: "f")) != nil,
                  "面板搜索快捷键应允许重设")
        try check(AppShortcut(event: try event(keyCode: kVK_Return, modifiers: [.command], text: "\r")) != nil,
                  "旧复制组合键应允许用于其他动作")
        try check(AppShortcut(event: try event(keyCode: kVK_Space, modifiers: [], text: " "),
                              requiresModifier: false) != nil,
                  "面板应允许单独设置空格键")
        try check(AppShortcut(event: try event(keyCode: kVK_ANSI_A, modifiers: [], text: "a"),
                              requiresModifier: false) == nil,
                  "单独的文字键不应截获搜索输入")
        try check(AppShortcutAction.copyOnly.defaultShortcut.displayName == "⌘C",
                  "仅复制应默认使用 ⌘C")
        try check(AppShortcutAction.allCases.map(\.defaultShortcut).count == 9,
                  "面板动作应各有默认快捷键")

        let suiteName = "ClipHoookShortcutSmoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try check(AppShortcutPreference.load("test", fallback: .defaultDeleteEntry, from: defaults)
                  == .defaultDeleteEntry, "未设置时应使用默认快捷键")
        AppShortcutPreference.save(custom, for: "test", in: defaults)
        try check(AppShortcutPreference.load("test", fallback: .defaultDeleteEntry, from: defaults)
                  == custom, "自定义快捷键未持久保存")

        try check(ShelfKeyboardAction.resolve(
            keyCode: UInt16(kVK_Delete), modifiers: [.command], searchFocused: true,
            searchIsEmpty: false
        ) == .deleteSelected, "搜索框有焦点时也应删除所选记录")
        try check(ShelfKeyboardAction.resolve(
            keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option], searchFocused: false,
            searchIsEmpty: true, shortcuts: [.deleteEntry: custom]
        ) == .deleteSelected, "自定义删除组合键未生效")
        try check(ShelfKeyboardAction.resolve(
            keyCode: UInt16(kVK_Delete), modifiers: [.command], searchFocused: false,
            searchIsEmpty: true, shortcuts: [.deleteEntry: custom]
        ) == nil, "更换快捷键后旧删除组合键应失效")
        for (action, expected) in [
            (AppShortcutAction.focusSearch, ShelfKeyboardAction.focusSearch),
            (.previous, .previous), (.next, .next),
            (.toggleDetail, .toggleDetail), (.paste, .paste),
            (.pastePlainText, .pastePlainText), (.copyOnly, .copyOnly)
        ] {
            let shortcut = action.defaultShortcut
            try check(ShelfKeyboardAction.resolve(
                keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                searchFocused: false, searchIsEmpty: true
            ) == expected, "\(action.title) 默认键未生效")
            try check(ShelfKeyboardAction.resolve(
                keyCode: custom.keyCode, modifiers: custom.modifiers,
                searchFocused: false, searchIsEmpty: true, shortcuts: [action: custom]
            ) == expected, "\(action.title) 自定义键未生效")
        }
        try check(ShelfKeyboardAction.resolve(
            keyCode: UInt16(kVK_ANSI_C), modifiers: [.command],
            searchFocused: true, searchIsEmpty: false
        ) == nil, "搜索输入时应保留系统复制文字快捷键")

        print("Shortcut smoke test passed")
    }

    private static func event(
        keyCode: Int, modifiers: NSEvent.ModifierFlags, text: String
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: UInt16(keyCode)
        ) else {
            throw ShortcutTestError.failed("无法构造键盘测试事件")
        }
        return event
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ShortcutTestError.failed(message) }
    }
}
