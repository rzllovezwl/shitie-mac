import AppKit
import Carbon

private enum Stage1KeyboardTestError: Error { case failed(String) }

@main
struct Stage1KeyboardSmoke {
    static func main() throws {
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
        print("Stage1 keyboard smoke test passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Stage1KeyboardTestError.failed(message) }
    }
}
