import AppKit
import Carbon

private enum ShortcutTestError: Error { case failed(String) }

@main
struct ShortcutSmoke {
    static func main() throws {
        try check(AppShortcut.defaultOpenPanel.displayName == "⌘⇧V", "默认唤起键显示错误")
        try check(AppShortcut.defaultDeleteEntry.displayName == "⌘⌫", "默认删除键显示错误")
        try check(AppShortcut.defaultDeleteEntry.carbonModifiers == UInt32(cmdKey), "Carbon 修饰键转换错误")
        try check(ScreenshotStartAction.annotate.selectionHints?.selection == nil,
                  "普通截图应保留默认的选区提示")
        try check(ScreenshotStartAction.translate.selectionHints?.selection.contains("翻译") == true
                  && ScreenshotStartAction.translate.selectionHints?.preparing.contains("翻译") == true,
                  "截图翻译的选区和准备提示必须说明翻译操作")
        try check(ScreenshotStartAction.recognizeText.selectionHints?.selection.contains("识别") == true
                  && ScreenshotStartAction.recognizeText.selectionHints?.preparing.contains("识别") == true,
                  "截图识别的选区和准备提示必须说明文字识别操作")
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
        try check(AppShortcutAction.copyPlainText.defaultShortcut.displayName == "⌘⇧C",
                  "复制纯文本应默认使用 ⌘⇧C")
        try check(AppShortcutAction.groupSelection.defaultShortcut.displayName == "⌘G" &&
                  AppShortcutAction.ungroupSelection.defaultShortcut.displayName == "⌘⇧G",
                  "成组和取消成组的默认快捷键错误")
        try check(AppShortcutAction.togglePinImage.defaultShortcut.displayName == "⌘T",
                  "钉在桌面的默认快捷键错误")
        try check(AppShortcutAction.toggleShelfPin.defaultShortcut.displayName == "⌘⇧T" &&
                  !AppShortcutAction.toggleShelfPin.isGlobal,
                  "面板卡片钉住应默认使用面板内的 ⌘⇧T")
        try check(AppShortcutAction.recognizeImageText.defaultShortcut.displayName == "⌘W",
                  "识别图片文字的默认快捷键错误")
        try check(AppShortcutAction.captureRegion.defaultShortcut.displayName == "⌥A",
                  "截图默认快捷键错误")
        try check(AppShortcutAction.captureScreen.defaultShortcut.displayName == "⌥W" &&
                  AppShortcutAction.captureScreen.isScreenshotCapture,
                  "整屏截图应默认使用可修改的全局快捷键 ⌥W")
        try check(AppShortcutAction.captureTranslate.defaultShortcut.hasSameKeys(as:
                    AppShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .option], keyLabel: "A")),
                  "截图翻译应默认 ⇧⌥A")
        try check(AppShortcutAction.captureRecognizeText.defaultShortcut.hasSameKeys(as:
                    AppShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .command], keyLabel: "A")),
                  "截图 OCR 应默认 ⇧⌘A")
        try check(AppShortcutAction.captureTranslate.screenshotStartAction == .translate &&
                  AppShortcutAction.captureRecognizeText.screenshotStartAction == .recognizeText &&
                  AppShortcutAction.captureRegion.screenshotStartAction == .annotate,
                  "截图选区完成后必须路由到对应动作")
        for action in [AppShortcutAction.captureTranslate, .captureRecognizeText, .captureScreen] {
            try check(action.isGlobal && action.requiresModifier, "直接截图工具必须可全局注册")
            try check(ShelfKeyboardAction.resolve(
                keyCode: action.defaultShortcut.keyCode, modifiers: action.defaultShortcut.modifiers,
                searchFocused: false, searchIsEmpty: true
            ) == nil, "全局截图键不应被面板的局部操作重复执行")
        }
        try check(AppShortcutAction.translateScreenshot.defaultShortcut.displayName == "⌘B",
                  "截图翻译默认快捷键错误")
        let suiteName = "ClipHoookShortcutSmoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let quickSearch = AppShortcutAction.quickSearch
        let quickSuite = suiteName + "-quick-search"
        let quickDefaults = UserDefaults(suiteName: quickSuite)!
        defer { quickDefaults.removePersistentDomain(forName: quickSuite) }
        try check(quickSearch.isGlobal && quickSearch.requiresModifier &&
                  quickSearch.defaultShortcut.displayName == "⌘⇧空格", "快速搜索默认键应为全局 Command Shift Space")
        try check(AppShortcutPreference.resolved(in: quickDefaults).shortcuts[quickSearch] == quickSearch.defaultShortcut,
                  "旧用户升级后应获得快速搜索默认键")
        AppShortcutPreference.save(custom, for: quickSearch.preferenceKey, in: quickDefaults)
        try check(AppShortcutPreference.resolved(in: quickDefaults).shortcuts[quickSearch] == custom,
                  "快速搜索自定义组合键需重启恢复")
        try check(ShelfKeyboardAction.resolve(keyCode: custom.keyCode, modifiers: custom.modifiers,
                  searchFocused: false, searchIsEmpty: true, shortcuts: [quickSearch: custom]) == nil,
                  "快速搜索全局键不能被面板键盘监听重复执行")
        quickDefaults.removeObject(forKey: quickSearch.preferenceKey)
        AppShortcutPreference.save(quickSearch.defaultShortcut, for: AppShortcutAction.focusSearch.preferenceKey, in: quickDefaults)
        let quickConflict = AppShortcutPreference.resolved(in: quickDefaults)
        try check(quickConflict.shortcuts[.focusSearch] == quickSearch.defaultShortcut &&
                  quickConflict.adjusted.contains(quickSearch), "新增默认搜索键不能覆盖用户原来的自定义键")
        let shelfSuite = suiteName + "-shelf-pin"
        let shelfDefaults = UserDefaults(suiteName: shelfSuite)!
        defer { shelfDefaults.removePersistentDomain(forName: shelfSuite) }
        let shelfPin = AppShortcutAction.toggleShelfPin
        try check(AppShortcutPreference.resolved(in: shelfDefaults).shortcuts[shelfPin] == shelfPin.defaultShortcut,
                  "新增面板钉住快捷键应载入默认键")
        AppShortcutPreference.save(custom, for: shelfPin.preferenceKey, in: shelfDefaults)
        let shelfShortcuts = AppShortcutPreference.resolved(in: shelfDefaults).shortcuts
        try check(shelfShortcuts[shelfPin] == custom && ShelfKeyboardAction.resolve(
            keyCode: shelfPin.defaultShortcut.keyCode, modifiers: shelfPin.defaultShortcut.modifiers,
            searchFocused: false, searchIsEmpty: true, shortcuts: shelfShortcuts
        ) == nil, "面板钉住快捷键应保存修改，旧按键应停止生效")
        let longScreenshot = AppShortcutAction.captureLongScreenshot
        let longSuite = suiteName + "-long"
        let longDefaults = UserDefaults(suiteName: longSuite)!
        defer { longDefaults.removePersistentDomain(forName: longSuite) }
        try check(longScreenshot.isGlobal && longScreenshot.requiresModifier &&
                  AppShortcutPreference.resolved(in: longDefaults).shortcuts[longScreenshot]?.displayName == "⌘⇧D",
                  "长截图应默认使用全局快捷键 ⌘⇧D")
        AppShortcutPreference.save(custom, for: longScreenshot.preferenceKey, in: longDefaults)
        try check(AppShortcutPreference.resolved(in: longDefaults).shortcuts[longScreenshot] == custom,
                  "长截图的自定义快捷键应能恢复")
        AppShortcutPreference.save(longScreenshot.defaultShortcut,
                                   for: longScreenshot.preferenceKey, in: longDefaults)
        try check(AppShortcutPreference.resolved(in: longDefaults).shortcuts[longScreenshot] ==
                    longScreenshot.defaultShortcut, "长截图快捷键应可恢复默认")
        AppShortcutPreference.save(longScreenshot.defaultShortcut,
                                   for: AppShortcutAction.toggleFavorite.preferenceKey, in: longDefaults)
        let longConflict = AppShortcutPreference.resolved(in: longDefaults)
        try check(longConflict.shortcuts[.toggleFavorite] == longScreenshot.defaultShortcut &&
                  longConflict.adjusted.contains(longScreenshot), "长截图默认键不应覆盖已有绑定")
        try check(AppShortcutPreference.load("test", fallback: .defaultDeleteEntry, from: defaults)
                  == .defaultDeleteEntry, "未设置时应使用默认快捷键")
        AppShortcutPreference.save(custom, for: "test", in: defaults)
        try check(AppShortcutPreference.load("test", fallback: .defaultDeleteEntry, from: defaults)
                  == custom, "自定义快捷键未持久保存")
        for action in [AppShortcutAction.captureTranslate, .captureRecognizeText, .captureScreen] {
            let captureSuite = suiteName + "-" + action.rawValue
            let captureDefaults = UserDefaults(suiteName: captureSuite)!
            defer { captureDefaults.removePersistentDomain(forName: captureSuite) }
            AppShortcutPreference.save(custom, for: action.preferenceKey, in: captureDefaults)
            let restored = AppShortcutPreference.resolved(in: captureDefaults)
            try check(restored.shortcuts[action]?.hasSameKeys(as: custom) == true,
                      "直接截图快捷键应保存并支持重启恢复")
        }

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
            (.pastePlainText, .pastePlainText), (.copyOnly, .copyOnly),
            (.copyPlainText, .copyPlainText),
            (.groupSelection, .groupSelection), (.ungroupSelection, .ungroupSelection),
            (.togglePinImage, .togglePinImage), (.toggleShelfPin, .toggleShelfPin),
            (.recognizeImageText, .recognizeImageText),
            (.annotateImage, .annotateImage), (.toggleFavorite, .toggleFavorite),
            (.translateScreenshot, .translate)
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
        for action in [AppShortcutAction.copyPlainText, .groupSelection,
                       .ungroupSelection, .togglePinImage, .toggleShelfPin, .recognizeImageText,
                       .annotateImage, .toggleFavorite, .translateScreenshot] {
            let shortcut = action.defaultShortcut
            try check(ShelfKeyboardAction.resolve(
                keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                searchFocused: true, searchIsEmpty: false
            ) == nil, "搜索输入时不应截获 \(action.title) 快捷键")
        }
        let screenshotTranslation = AppShortcutAction.translateScreenshot.defaultShortcut
        try check(ShelfKeyboardAction.resolve(
            keyCode: screenshotTranslation.keyCode,
            modifiers: screenshotTranslation.modifiers,
            searchFocused: false, searchIsEmpty: true
        ) == .translate, "翻译键应统一用于面板与截图")

        try check(AppShortcutAction.annotateImage.defaultShortcut.displayName == "⌘E" &&
                  AppShortcutAction.toggleFavorite.defaultShortcut.displayName == "⌘D", "新增标注和收藏默认键错误")
        AppShortcutPreference.save(AppShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command], keyLabel: "D"),
                                   for: AppShortcutAction.recognizeImageText.preferenceKey, in: defaults)
        AppShortcutPreference.save(AppShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift], keyLabel: "D"),
                                   for: AppShortcutAction.translateScreenshot.preferenceKey, in: defaults)
        let migrated = AppShortcutPreference.resolved(in: defaults)
        try check(migrated.shortcuts[.recognizeImageText]?.displayName == "⌘W" &&
                  migrated.shortcuts[.translateScreenshot]?.displayName == "⌘B" &&
                  migrated.shortcuts[.toggleFavorite]?.displayName == "⌘D", "旧默认快捷键迁移产生冲突")
        AppShortcutPreference.save(custom, for: AppShortcutAction.recognizeImageText.preferenceKey, in: defaults)
        let preserved = AppShortcutPreference.resolved(in: defaults)
        try check(preserved.shortcuts[.recognizeImageText] == custom, "自定义识别快捷键未保留")
        let commandD = AppShortcutAction.toggleFavorite.defaultShortcut
        AppShortcutPreference.save(commandD, for: AppShortcutAction.focusSearch.preferenceKey, in: defaults)
        let conflicts = AppShortcutPreference.resolved(in: defaults)
        try check(conflicts.shortcuts[.focusSearch] == commandD &&
                  conflicts.shortcuts[.toggleFavorite]?.hasSameKeys(as: commandD) == false &&
                  conflicts.adjusted.contains(.toggleFavorite), "新增默认键不应覆盖已有自定义按键")
        let values = Array(conflicts.shortcuts.values)
        for i in values.indices {
            try check(!values.indices.contains { $0 != i && values[$0].hasSameKeys(as: values[i]) }, "升级后快捷键重复")
        }

        let saveAction = AppShortcutAction.saveImageToFile
        let saveShortcut = saveAction.defaultShortcut
        try check(saveShortcut.displayName == "⌘S" && !saveAction.isGlobal && saveAction.requiresModifier,
                  "保存图片应默认使用仅在相关窗口生效的 ⌘S")
        try check(ShelfKeyboardAction.resolve(keyCode: saveShortcut.keyCode,
            modifiers: saveShortcut.modifiers, searchFocused: true, searchIsEmpty: false) == .saveImageToFile,
            "搜索图片时仍应能保存选中卡片")
        let customSave = AppShortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command, .shift], keyLabel: "S")
        AppShortcutPreference.save(customSave, for: saveAction.preferenceKey, in: defaults)
        let savedBindings = AppShortcutPreference.resolved(in: defaults).shortcuts
        try check(ShelfKeyboardAction.resolve(keyCode: customSave.keyCode,
            modifiers: customSave.modifiers, searchFocused: false, searchIsEmpty: true,
            shortcuts: savedBindings) == .saveImageToFile, "保存图片应使用设置中的新按键")
        try check(ShelfKeyboardAction.resolve(keyCode: saveShortcut.keyCode,
            modifiers: saveShortcut.modifiers, searchFocused: false, searchIsEmpty: true,
            shortcuts: savedBindings) == nil, "修改保存快捷键后，旧快捷键应停止触发")
        defaults.removeObject(forKey: saveAction.preferenceKey)

        let annotationKeys: [(AppShortcutAction, String)] = [
            (.annotationRectangle, "R"), (.annotationEllipse, "O"), (.annotationText, "T"),
            (.annotationBrush, "L"), (.annotationArrow, "E"), (.annotationMosaic, "M"),
            (.annotationPen, "P"), (.annotationDiscard, "X")
        ]
        for (action, key) in annotationKeys {
            let shortcut = action.defaultShortcut
            try check(shortcut.displayName == key && action.accepts(shortcut) && !action.isGlobal,
                      "标注字母快捷键的默认值和作用域错误")
            try check(!shortcut.isValidForPanel && !shortcut.isValid,
                      "标注字母单键不得放宽面板或全局快捷键限制")
            for focused in [false, true] {
                try check(ShelfKeyboardAction.resolve(keyCode: shortcut.keyCode, modifiers: [],
                    searchFocused: focused, searchIsEmpty: true) == nil,
                    "面板和搜索不应截获标注工具的字母单键")
            }
        }
        let r = AppShortcutAction.annotationRectangle.defaultShortcut
        try check(AppShortcutPreference.annotationAction(keyCode: r.keyCode, modifiers: [.capsLock],
            inputActive: false, shortcuts: [:]) == .annotationRectangle,
            "标注单键应按物理按键匹配，不受大写锁定影响")
        try check(AppShortcutPreference.annotationAction(keyCode: r.keyCode, modifiers: [],
            inputActive: true, shortcuts: [:]) == nil,
            "文字输入、识别弹窗或文件选择中的字母键不得切换标注工具")
        let annotationEvent = try event(keyCode: kVK_ANSI_S, modifiers: [], text: "s")
        let annotationShortcut = AppShortcut(event: annotationEvent, requiresModifier: false, allowsPrintableKey: true)!
        try check(annotationShortcut.displayName == "S", "应能录制标注用字母单键")
        AppShortcutPreference.save(annotationShortcut, for: AppShortcutAction.annotationPen.preferenceKey, in: defaults)
        try check(AppShortcutPreference.resolved(in: defaults).shortcuts[.annotationPen] == annotationShortcut,
                  "标注工具的自定义单键应持久保存")
        let discard = AppShortcutAction.annotationDiscard
        let x = discard.defaultShortcut
        try check(AppShortcutPreference.annotationAction(keyCode: x.keyCode, modifiers: [],
            inputActive: false, shortcuts: [:]) == discard, "X 应切换划除工具")
        try check(AppShortcutPreference.annotationAction(keyCode: x.keyCode, modifiers: [],
            inputActive: true, shortcuts: [:]) == nil, "输入文字时 X 应保留为文字")
        let customDiscard = AppShortcut(keyCode: UInt16(kVK_ANSI_Y), modifiers: [], keyLabel: "Y")
        AppShortcutPreference.save(customDiscard, for: discard.preferenceKey, in: defaults)
        let discardBindings = AppShortcutPreference.resolved(in: defaults).shortcuts
        try check(AppShortcutPreference.annotationAction(keyCode: customDiscard.keyCode, modifiers: [],
            inputActive: false, shortcuts: discardBindings) == discard, "划除应使用保存的自定义按键")
        try check(AppShortcutPreference.annotationAction(keyCode: x.keyCode, modifiers: [],
            inputActive: false, shortcuts: discardBindings) == nil, "自定义后应释放原来的 X")
        for reserved in [kVK_Return, kVK_Escape, kVK_Delete, kVK_LeftArrow] {
            try check(!AppShortcut(keyCode: UInt16(reserved), modifiers: [], keyLabel: "x").isValidForAnnotation,
                      "标注工具不可覆盖完成、取消、删除或导航键")
        }
        try check(!AppShortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command], keyLabel: "Z").isValidForAnnotation,
                  "标注工具不可覆盖撤销键")
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
