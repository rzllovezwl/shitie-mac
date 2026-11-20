import AppKit
import Carbon

private enum Stage1KeyboardTestError: Error { case failed(String) }

@main
struct Stage1KeyboardSmoke {
    @MainActor static func main() throws {
        func action(
            _ code: Int,
            _ modifiers: NSEvent.ModifierFlags = [],
            searchFocused: Bool = true,
            searchIsEmpty: Bool = false
        ) -> ShelfKeyboardAction? {
            ShelfKeyboardAction.resolve(
                keyCode: UInt16(code), modifiers: modifiers,
                searchFocused: searchFocused, searchIsEmpty: searchIsEmpty
            )
        }

        try check(action(kVK_Return) == .paste, "回车应保留原格式粘贴")
        try check(action(kVK_ANSI_KeypadEnter) == .paste, "小键盘回车应粘贴")
        try check(action(kVK_Return, [.option]) == .pastePlainText, "Option+回车应纯文本粘贴")
        try check(action(kVK_Return, [.command]) == nil, "旧的 Command+回车复制键应已移除")
        try check(action(kVK_ANSI_C, [.command], searchFocused: false) == .copyOnly,
                  "Command+C 应只复制所选记录")
        try check(action(kVK_ANSI_C, [.command]) == nil,
                  "搜索框有焦点时 Command+C 应留给文字复制")
        try check(action(kVK_ANSI_C, [.command, .shift], searchFocused: false) == .copyPlainText,
                  "Command+Shift+C 应复制纯文本")
        try check(action(kVK_ANSI_G, [.command], searchFocused: false) == .groupSelection &&
                  action(kVK_ANSI_G, [.command, .shift], searchFocused: false) == .ungroupSelection,
                  "Command+G 和 Command+Shift+G 应操作分组")
        try check(action(kVK_ANSI_T, [.command], searchFocused: false) == .togglePinImage,
                  "Command+T 应切换当前图片的贴图状态")
        try check(action(kVK_ANSI_W, [.command], searchFocused: false) == .recognizeImageText,
                  "Command+W 应识别当前图片")
        try check(action(kVK_ANSI_D, [.command], searchFocused: false) == .toggleFavorite &&
                  action(kVK_ANSI_E, [.command], searchFocused: false) == .annotateImage &&
                  action(kVK_ANSI_B, [.command], searchFocused: false) == .translate,
                  "收藏、标注与翻译默认键应生效")
        try check(action(kVK_ANSI_C, [.command, .shift]) == nil &&
                  action(kVK_ANSI_G, [.command]) == nil &&
                  action(kVK_ANSI_G, [.command, .shift]) == nil &&
                  action(kVK_ANSI_T, [.command]) == nil &&
                  action(kVK_ANSI_D, [.command]) == nil,
                  "搜索框输入时不应执行复制、分组或识别图片")
        try check(action(kVK_Return, [.shift]) == nil, "输入法或编辑快捷键不应误触发粘贴")
        try check(action(kVK_UpArrow) == .previous && action(kVK_DownArrow) == .next,
                  "搜索输入期间上下键应切换记录")
        try check(action(kVK_LeftArrow) == nil && action(kVK_RightArrow) == nil,
                  "有搜索词时左右键应留给文本光标")
        try check(action(kVK_LeftArrow, searchIsEmpty: true) == .previous
                  && action(kVK_RightArrow, searchIsEmpty: true) == .next,
                  "空搜索时左右键应切换记录")
        try check(action(kVK_LeftArrow, searchFocused: false) == .previous,
                  "列表焦点下左右键应切换记录")
        try check(action(kVK_Space) == nil && action(kVK_Space, searchFocused: false) == .toggleDetail,
                  "空格输入与详情快捷键不能冲突")
        try check(action(kVK_Escape) == .dismiss && action(kVK_ANSI_F, [.command]) == .focusSearch,
                  "退出与搜索快捷键不正确")
        try check(action(kVK_DownArrow, [.command]) == nil, "带修饰键的方向键不能误导航")
        let edit = AppShortcutAction.annotateImage.defaultShortcut
        try check(ShelfKeyboardAction.resolve(
            keyCode: edit.keyCode, modifiers: edit.modifiers,
            searchFocused: false, searchIsEmpty: true, textEditingAvailable: true
        ) == .editText, "文字或链接卡片应由默认 ⌘E 直接进入编辑")
        try check(ShelfKeyboardAction.resolve(
            keyCode: edit.keyCode, modifiers: edit.modifiers,
            searchFocused: false, searchIsEmpty: true, textEditingAvailable: false
        ) == .annotateImage, "同一快捷键在图片卡片上应继续进入标注")
        let customEdit = AppShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option], keyLabel: "K")
        let editShortcuts: [AppShortcutAction: AppShortcut] = [.annotateImage: customEdit]
        try check(ShelfKeyboardAction.resolve(
            keyCode: customEdit.keyCode, modifiers: customEdit.modifiers,
            searchFocused: false, searchIsEmpty: true, textEditingAvailable: true,
            shortcuts: editShortcuts
        ) == .editText, "改键后文字编辑必须使用新的快捷键")
        try check(ShelfKeyboardAction.resolve(
            keyCode: edit.keyCode, modifiers: edit.modifiers,
            searchFocused: false, searchIsEmpty: true, textEditingAvailable: true,
            shortcuts: editShortcuts
        ) == nil, "更改编辑快捷键后，原 ⌘E 不应继续生效")
        try check(ShelfKeyboardAction.resolve(
            keyCode: edit.keyCode, modifiers: edit.modifiers,
            searchFocused: true, searchIsEmpty: false, textEditingAvailable: true
        ) == nil, "搜索框正在编辑时，不应截走搜索文字的编辑按键")
        try checkWindowRouting()
        try checkScopedEditHotKey()
        print("Stage1 keyboard smoke test passed: native equivalents, scoped edit registration/dispatch/release, windowless focus, input isolation, custom bindings and monitor replacement")
    }

    @MainActor
    private static func checkWindowRouting() throws {
        _ = NSApplication.shared
        let panel = KeyboardTestPanel(contentRect: CGRect(x: -100000, y: -100000, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = ShelfKeyMonitor.KeyView()
        let coordinator = ShelfKeyMonitor.Coordinator()
        coordinator.view = view
        view.coordinator = coordinator
        panel.contentView = view
        var actions: [ShelfKeyboardAction] = []
        var searchFocused = false
        var textEditing = false
        var shortcuts: [AppShortcutAction: AppShortcut] = [:]
        coordinator.onKeyDown = { event in
            guard let action = ShelfKeyboardAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
                searchFocused: searchFocused, searchIsEmpty: true, textEditingAvailable: textEditing,
                shortcuts: shortcuts) else { return false }
            actions.append(action)
            return true
        }
        func event(window: NSWindow? = nil, custom: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: custom ? [.control, .option] : .command,
                timestamp: 1, windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: custom ? "k" : "e", charactersIgnoringModifiers: custom ? "k" : "e",
                isARepeat: false, keyCode: UInt16(custom ? kVK_ANSI_K : kVK_ANSI_E))!
        }
        let windowless = event()
        try check(windowless.window == nil, "测试按键必须没有关联窗口")
        try check(panel.shelfKeyMonitor === coordinator && panel.performKeyEquivalent(with: windowless)
                  && actions == [.annotateImage],
                  "面板持有键盘焦点时，没有窗口编号的 ⌘E 也应触发图片标注")
        let targeted = event(window: panel)
        try check(targeted.window === panel, "定向事件必须实际关联离屏面板")
        panel.testKeyWindow = false
        try check(coordinator.handle(targeted) && actions.count == 2,
                  "已明确发给面板的快捷键不能因非激活浮层的焦点状态而遗漏")
        try check(!coordinator.handle(windowless) && actions.count == 2,
                  "没有焦点的面板不能截走无窗口的快捷键")
        panel.testKeyWindow = true
        panel.testVisible = false
        try check(!coordinator.handle(targeted), "隐藏面板不能继续响应快捷键")
        panel.testVisible = true
        let other = NSWindow(contentRect: CGRect(x: -100000, y: -100000, width: 100, height: 80),
            styleMask: .borderless, backing: .buffered, defer: false)
        try check(!coordinator.handle(event(window: other)), "其他窗口的输入不能触发卡片操作")
        searchFocused = true
        try check(!coordinator.handle(windowless), "搜索框中不能截走原生文字编辑快捷键")
        searchFocused = false
        textEditing = true
        try check(panel.performKeyEquivalent(with: windowless) && actions.last == .editText,
                  "文字卡片的原生 ⌘E 入口也应进入文字编辑")
        let input = KeyboardMarkedTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        view.addSubview(input)
        try check(panel.makeFirstResponder(input), "离屏输入控件应可获得焦点")
        let count = actions.count
        try check(!coordinator.handle(windowless) && actions.count == count,
                  "输入法组合文字时，原生入口不能操作卡片")
        panel.makeFirstResponder(nil)
        textEditing = false
        shortcuts[.annotateImage] = AppShortcut(keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .option], keyLabel: "K")
        try check(!coordinator.handle(windowless) && panel.performKeyEquivalent(with: event(custom: true))
                  && actions.last == .annotateImage, "改键后两种入口都应沿用新的快捷键")
        let replacement = ShelfKeyMonitor.Coordinator()
        replacement.attach(to: panel)
        coordinator.remove()
        try check(panel.shelfKeyMonitor === replacement,
                  "旧视图拆除不能清除重建后的快捷键处理器")
        replacement.remove()
        try check(panel.shelfKeyMonitor == nil, "处理器移除后不得残留窗口快捷键回调")
        panel.contentView = nil
    }

    @MainActor
    private static func checkScopedEditHotKey() throws {
        let panel = KeyboardTestPanel(contentRect: CGRect(x: -100000, y: -100000, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let spy = KeyboardHotKeySpy()
        let coordinator = ShelfKeyMonitor.Coordinator(editHotKey: spy)
        let view = ShelfKeyMonitor.KeyView()
        coordinator.view = view
        view.coordinator = coordinator
        panel.contentView = view
        var actions: [ShelfKeyboardAction] = []
        var bindings: [AppShortcutAction: AppShortcut] = [:]
        coordinator.onKeyDown = { event in
            guard let action = ShelfKeyboardAction.resolve(keyCode: event.keyCode,
                modifiers: event.modifierFlags, searchFocused: false, searchIsEmpty: true,
                shortcuts: bindings) else { return false }
            actions.append(action)
            return true
        }
        let edit = AppShortcutAction.annotateImage.defaultShortcut
        coordinator.setEditShortcut(edit)
        try check(spy.shortcut == edit && spy.registrations == 1, "只有可见且持有焦点的卡片面板才注册编辑键")
        coordinator.refreshEditShortcut()
        try check(spy.registrations == 1, "窗口更新不得反复注册同一组合键")
        coordinator.performScopedEditShortcut()
        try check(actions == [.annotateImage], "临时快捷键必须调用同一图片标注处理器一次")
        coordinator.setEditShortcut(nil)
        coordinator.performScopedEditShortcut()
        try check(spy.shortcut == nil && actions.count == 1, "进入搜索或没有可编辑卡片时必须释放按键")
        coordinator.setEditShortcut(edit)
        panel.testKeyWindow = false
        coordinator.refreshEditShortcut()
        coordinator.performScopedEditShortcut()
        try check(spy.shortcut == nil && actions.count == 1, "面板失去焦点后不得截走其他应用的编辑键")
        panel.testKeyWindow = true
        panel.testVisible = false
        coordinator.refreshEditShortcut()
        try check(spy.shortcut == nil, "收起面板后必须释放编辑键")
        panel.testVisible = true
        let input = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        view.addSubview(input)
        _ = panel.makeFirstResponder(input)
        coordinator.refreshEditShortcut()
        try check(spy.shortcut == nil, "实际输入框持有焦点时不得注册卡片快捷键")
        panel.makeFirstResponder(nil)
        let custom = AppShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option], keyLabel: "K")
        bindings[.annotateImage] = custom
        coordinator.setEditShortcut(custom)
        coordinator.performScopedEditShortcut()
        try check(spy.shortcut == custom && actions == [.annotateImage, .annotateImage],
                  "自定义编辑键必须注册并通过同一业务路由执行")
        let nextSpy = KeyboardHotKeySpy()
        let next = ShelfKeyMonitor.Coordinator(editHotKey: nextSpy)
        let nextView = ShelfKeyMonitor.KeyView()
        next.view = nextView
        nextView.coordinator = next
        view.addSubview(nextView)
        next.setEditShortcut(custom)
        try check(spy.shortcut == nil && nextSpy.shortcut == custom,
                  "重建时先释放旧注册，新处理器才能接管同一组合键")
        coordinator.remove()
        coordinator.performScopedEditShortcut()
        try check(spy.shortcut == nil && nextSpy.shortcut == custom && actions.count == 2,
                  "移除旧面板不得注销新处理器，也不得执行过期回调")
        next.remove()
        try check(nextSpy.shortcut == nil, "最终移除必须释放临时注册")
        panel.contentView = nil
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Stage1KeyboardTestError.failed(message) }
    }
}

private final class KeyboardTestPanel: ShelfKeyboardPanel {
    var testKeyWindow = true
    var testVisible = true
    override var isKeyWindow: Bool { testKeyWindow }
    override var isVisible: Bool { testVisible }
}

private final class KeyboardMarkedTextView: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

@MainActor
private final class KeyboardHotKeySpy: ShelfEditHotKey {
    private(set) var shortcut: AppShortcut?
    private(set) var registrations = 0
    func register(_ shortcut: AppShortcut, allowsUnmodified: Bool, allowsPrintableKey: Bool) -> Bool {
        self.shortcut = shortcut
        registrations += 1
        return true
    }
    func unregister() { shortcut = nil }
}
