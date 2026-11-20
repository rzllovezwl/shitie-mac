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

    init?(event: NSEvent, requiresModifier: Bool = true, allowsPrintableKey: Bool = false) {
        guard let label = Self.label(for: event) else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, keyLabel: label)
        guard allowsPrintableKey ? isValidForAnnotation : (requiresModifier ? isValid : isValidForPanel) else { return nil }
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

    /// Printable single keys are scoped to an annotation canvas, never the
    /// clipboard panel or a text editor. Keep editing/navigation keys reserved.
    var isValidForAnnotation: Bool {
        guard !keyLabel.isEmpty, keyLabel.count <= 4,
              !Self.modifierOnlyKeyCodes.contains(Int(keyCode)),
              ![kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Space,
                kVK_Delete, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
                kVK_UpArrow, kVK_DownArrow].contains(Int(keyCode)) else { return false }
        if modifiers.contains(.command),
           [kVK_ANSI_Z, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_A].contains(Int(keyCode)) {
            return false
        }
        return true
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

enum ScreenshotStartAction: String {
    case annotate, recognizeText, translate

    var selectionHints: (selection: String, preparing: String)? {
        switch self {
        case .annotate: nil
        case .recognizeText:
            ("选区后识别文字", "正在准备识别…")
        case .translate:
            ("选区后翻译", "正在准备翻译…")
        }
    }
}

enum AppShortcutAction: String, CaseIterable, Hashable {
    case openPanel, quickSearch, deleteEntry, focusSearch, previous, next
    case toggleDetail, paste, pastePlainText, copyOnly
    case copyPlainText, groupSelection, ungroupSelection, togglePinImage, recognizeImageText
    case annotateImage, saveImageToFile, toggleFavorite, toggleShelfPin
    case captureRegion, captureScreen, captureLongScreenshot, captureTranslate, captureRecognizeText, translateScreenshot
    case recordScreen, pauseScreenRecording
    case annotationRectangle, annotationEllipse, annotationText, annotationBrush
    case annotationArrow, annotationMosaic, annotationPen
    case annotationDiscard

    var isAnnotationTool: Bool {
        switch self {
        case .annotationRectangle, .annotationEllipse, .annotationText, .annotationBrush,
             .annotationArrow, .annotationMosaic, .annotationPen, .annotationDiscard: true
        default: false
        }
    }

    func accepts(_ shortcut: AppShortcut) -> Bool {
        isAnnotationTool ? shortcut.isValidForAnnotation
            : (requiresModifier ? shortcut.isValid : shortcut.isValidForPanel)
    }

    var screenshotStartAction: ScreenshotStartAction? {
        switch self {
        case .captureRegion: .annotate
        case .captureTranslate: .translate
        case .captureRecognizeText: .recognizeText
        default: nil
        }
    }

    var isScreenshotCapture: Bool { screenshotStartAction != nil || self == .captureScreen || self == .captureLongScreenshot }

    var isGlobal: Bool {
        self == .openPanel || self == .quickSearch || isScreenshotCapture || isScreenRecording
    }

    var isScreenRecording: Bool { self == .recordScreen || self == .pauseScreenRecording }

    var requiresModifier: Bool { isGlobal || self == .translateScreenshot || self == .saveImageToFile }

    var title: String {
        switch self {
        case .openPanel: "唤起或收起面板"
        case .quickSearch: "全局快速搜索"
        case .deleteEntry: "删除选中的记录"
        case .focusSearch: "搜索历史"
        case .previous: "上一条记录"
        case .next: "下一条记录"
        case .toggleDetail: "打开或关闭预览"
        case .paste: "按设置粘贴"
        case .pastePlainText: "纯文本粘贴"
        case .copyOnly: "仅复制"
        case .copyPlainText: "复制纯文本"
        case .groupSelection: "将所选卡片成组"
        case .ungroupSelection: "取消成组"
        case .togglePinImage: "钉住或取消钉住图片"
        case .recognizeImageText: "识别图片文字"
        case .annotateImage: "编辑文字或标注图片"
        case .saveImageToFile: "保存图片到文件"
        case .toggleFavorite: "收藏或取消收藏"
        case .toggleShelfPin: "钉住或取消钉住卡片"
        case .captureRegion: "截图（选窗口或拖区域）"
        case .captureScreen: "整个屏幕截图"
        case .captureLongScreenshot: "长截图"
        case .captureTranslate: "截图后直接翻译"
        case .captureRecognizeText: "截图后直接识别文字"
        case .translateScreenshot: "翻译文字或截图"
        case .recordScreen: "开始或结束录屏"
        case .pauseScreenRecording: "暂停或继续录屏"
        case .annotationRectangle: "矩形工具"
        case .annotationEllipse: "椭圆工具"
        case .annotationText: "文字工具"
        case .annotationBrush: "画笔工具"
        case .annotationArrow: "箭头工具"
        case .annotationMosaic: "马赛克与背景模糊工具"
        case .annotationPen: "钢笔工具"
        case .annotationDiscard: "划除工具"
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
        case .quickSearch: AppShortcut(keyCode: UInt16(kVK_Space), modifiers: [.command, .shift], keyLabel: "空格")
        case .deleteEntry: .defaultDeleteEntry
        case .focusSearch: AppShortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: [.command], keyLabel: "F")
        case .previous: AppShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: [], keyLabel: "←")
        case .next: AppShortcut(keyCode: UInt16(kVK_RightArrow), modifiers: [], keyLabel: "→")
        case .toggleDetail: AppShortcut(keyCode: UInt16(kVK_Space), modifiers: [], keyLabel: "空格")
        case .paste: AppShortcut(keyCode: UInt16(kVK_Return), modifiers: [], keyLabel: "↩")
        case .pastePlainText: AppShortcut(keyCode: UInt16(kVK_Return), modifiers: [.option], keyLabel: "↩")
        case .copyOnly: AppShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command], keyLabel: "C")
        case .copyPlainText: AppShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift], keyLabel: "C")
        case .groupSelection: AppShortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command], keyLabel: "G")
        case .ungroupSelection: AppShortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command, .shift], keyLabel: "G")
        case .togglePinImage: AppShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command], keyLabel: "T")
        case .recognizeImageText: AppShortcut(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command], keyLabel: "W")
        case .annotateImage: AppShortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: [.command], keyLabel: "E")
        case .saveImageToFile: AppShortcut(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command], keyLabel: "S")
        case .toggleFavorite: AppShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command], keyLabel: "D")
        case .toggleShelfPin: AppShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .shift], keyLabel: "T")
        case .captureRegion: AppShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.option], keyLabel: "A")
        case .captureScreen: AppShortcut(keyCode: UInt16(kVK_ANSI_W), modifiers: [.option], keyLabel: "W")
        case .captureLongScreenshot: AppShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift], keyLabel: "D")
        case .captureTranslate: AppShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .option], keyLabel: "A")
        case .captureRecognizeText: AppShortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift, .command], keyLabel: "A")
        case .translateScreenshot: AppShortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: [.command], keyLabel: "B")
        case .recordScreen: AppShortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.option], keyLabel: "R")
        case .pauseScreenRecording: AppShortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [.option, .shift], keyLabel: "R")
        case .annotationRectangle: AppShortcut(keyCode: UInt16(kVK_ANSI_R), modifiers: [], keyLabel: "R")
        case .annotationEllipse: AppShortcut(keyCode: UInt16(kVK_ANSI_O), modifiers: [], keyLabel: "O")
        case .annotationText: AppShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [], keyLabel: "T")
        case .annotationBrush: AppShortcut(keyCode: UInt16(kVK_ANSI_L), modifiers: [], keyLabel: "L")
        case .annotationArrow: AppShortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: [], keyLabel: "E")
        case .annotationMosaic: AppShortcut(keyCode: UInt16(kVK_ANSI_M), modifiers: [], keyLabel: "M")
        case .annotationPen: AppShortcut(keyCode: UInt16(kVK_ANSI_P), modifiers: [], keyLabel: "P")
        case .annotationDiscard: AppShortcut(keyCode: UInt16(kVK_ANSI_X), modifiers: [], keyLabel: "X")
        }
    }
}

enum AppShortcutPreference {
    static let openPanelKey = "openPanelShortcut"
    static let deleteEntryKey = "deleteEntryShortcut"

    static func annotationAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                                 inputActive: Bool,
                                 shortcuts: [AppShortcutAction: AppShortcut]) -> AppShortcutAction? {
        guard !inputActive else { return nil }
        return AppShortcutAction.allCases.first { action in
            action.isAnnotationTool && (shortcuts[action] ?? action.defaultShortcut)
                .matches(keyCode: keyCode, modifiers: modifiers)
        }
    }

    struct Resolution {
        let shortcuts: [AppShortcutAction: AppShortcut]
        let adjusted: [AppShortcutAction]
    }

    static func resolved(in defaults: UserDefaults = .standard) -> Resolution {
        let migrationKey = "unifiedToolShortcutDefaultsV203"
        if !defaults.bool(forKey: migrationKey) {
            let legacy: [(AppShortcutAction, AppShortcut)] = [
                (.recognizeImageText, AppShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command], keyLabel: "D")),
                (.translateScreenshot, AppShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift], keyLabel: "D"))
            ]
            for (action, oldDefault) in legacy where defaults.data(forKey: action.preferenceKey) != nil {
                let saved = load(action.preferenceKey, fallback: action.defaultShortcut,
                                 from: defaults, requiresModifier: action.requiresModifier)
                if saved.hasSameKeys(as: oldDefault) {
                    save(action.defaultShortcut, for: action.preferenceKey, in: defaults)
                }
            }
            defaults.set(true, forKey: migrationKey)
        }
        let actions = AppShortcutAction.allCases
        let candidates = Dictionary(uniqueKeysWithValues: actions.map { action in
            (action, load(action.preferenceKey, fallback: action.defaultShortcut,
                          from: defaults, requiresModifier: action.requiresModifier,
                          allowsPrintableKey: action.isAnnotationTool))
        })
        let custom = actions.filter {
            defaults.data(forKey: $0.preferenceKey) != nil && candidates[$0] != $0.defaultShortcut
        }
        let order = custom + actions.filter { !custom.contains($0) }
        var result: [AppShortcutAction: AppShortcut] = [:]
        var adjusted: [AppShortcutAction] = []
        for action in order {
            let candidate = candidates[action]!
            let fallbackModifiers: [NSEvent.ModifierFlags] = [
                [.control, .option], [.control, .option, .shift],
                [.command, .option], [.command, .option, .shift],
                [.command, .control], [.command, .control, .shift]
            ]
            var choices = [candidate, action.defaultShortcut] + fallbackModifiers.map {
                AppShortcut(keyCode: action.defaultShortcut.keyCode, modifiers: $0,
                            keyLabel: action.defaultShortcut.keyLabel)
            }
            choices += [(kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
                        (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
                        (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12")].map {
                AppShortcut(keyCode: UInt16($0.0), modifiers: [.control, .option], keyLabel: $0.1)
            }
            let chosen = choices.first { proposed in
                !result.values.contains { $0.hasSameKeys(as: proposed) }
            }!
            result[action] = chosen
            if !chosen.hasSameKeys(as: candidate) { adjusted.append(action) }
        }
        return Resolution(shortcuts: result, adjusted: adjusted)
    }

    static func load(_ key: String, fallback: AppShortcut, from defaults: UserDefaults = .standard,
                     requiresModifier: Bool = true, allowsPrintableKey: Bool = false) -> AppShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(AppShortcut.self, from: data),
              (allowsPrintableKey ? shortcut.isValidForAnnotation
                  : (requiresModifier ? shortcut.isValid : shortcut.isValidForPanel)) else { return fallback }
        return shortcut
    }

    static func save(_ shortcut: AppShortcut, for key: String, in defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }
}

struct ClipboardPreviewActionRequest: Equatable {
    let id = UUID()
    let entryID: UUID
    let action: AppShortcutAction
}
