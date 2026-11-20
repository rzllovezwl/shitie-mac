import AppKit
import Carbon
import Foundation

private enum SearchTestError: Error { case failed(String) }

@main
struct QuickSearchSmoke {
    @MainActor
    static func main() async throws {
        var exact = text("我的", time: 10)
        exact.shelfPinOrder = 99
        let prefix = text("我的日程", time: 20)
        let body = text("工作笔记\n这里保存了我的计划", time: 30)
        var image = entry(.image, time: 40)
        image.ocrText = "我的订单已付款"
        var file = entry(.fileReference, time: 50)
        file.fileName = "我的计划.PNG"
        file.sourceAppName = "微信"
        let roots = [image, body, exact, file, prefix]
        let found = ClipboardQuickSearch.results(in: roots, query: "我的")
        try check(found.map(\.id) == [exact.id, file.id, prefix.id, image.id, body.id],
                  "应按完整标题、标题前缀、正文命中排序，同级按复制时间排序")
        try check(found.first(where: { $0.id == image.id })?.summary.contains("我的") == true,
                  "图片 OCR 命中应显示文字摘要")
        try check(ClipboardQuickSearch.results(in: roots, query: "微信 PNG").map(\.id) == [file.id],
                  "多个关键词应同时匹配，可横跨文件名和来源，且不区分大小写")
        try check(ClipboardQuickSearch.results(in: roots, query: "微信 不存在").isEmpty,
                  "部分关键词命中不能当作完整结果")
        try check(ClipboardQuickSearch.results(in: [file], query: " png ").count == 1,
                  "首尾空格与大小写不应影响搜索")

        let first = text("分组内的合同", time: 80)
        let second = text("另一个成员", time: 81)
        var group = entry(.group, time: 90)
        group.groupMembers = [first, second]
        group.groupMemberIDs = [first.id, second.id]
        try check(ClipboardQuickSearch.results(in: [group], query: "合同").map(\.id) == [first.id],
                  "分组应返回命中的成员，不能误粘贴整组")
        try check(ClipboardQuickSearch.results(in: [group], query: "合同 另一个").isEmpty,
                  "不同成员的关键词不能拼接成同一命中")
        try check(ClipboardQuickSearch.results(in: [group, first], query: "合同").count == 1,
                  "相同成员不可重复展示")
        try check(ClipboardQuickSearch.results(in: [group], query: "").map(\.id) == [group.id],
                  "未输入时应保留最近分组的原始身份")

        var recent = (0..<12).map { text("记录 \($0)", time: TimeInterval($0)) }
        recent[0].shelfPinOrder = 1
        recent[1].isFavorite = true
        let latest = ClipboardQuickSearch.results(in: recent, query: " \n ")
        try check(latest.map(\.id) == recent.suffix(10).reversed().map(\.id),
                  "最近十条按实际复制时间，不能被收藏、钉住或面板自定义排序干扰")
        let oldSelection = latest[4].id
        try check(ClipboardQuickSearch.selection(after: latest, previous: oldSelection, preserve: true) == oldSelection,
                  "后台 OCR 补充结果不能跳走用户的选择")
        try check(ClipboardQuickSearch.selection(after: latest, previous: UUID(), preserve: true) == latest[0].id,
                  "删除所选条目后应回到有效结果")
        try check(ClipboardQuickSearch.selection(after: latest, previous: oldSelection, preserve: false) == latest[0].id,
                  "新关键词应选择首条结果")
        try check(ClipboardQuickSearch.moving(latest[0].id, by: -1, in: latest) == latest[0].id &&
                  ClipboardQuickSearch.moving(latest.last!.id, by: 1, in: latest) == latest.last!.id &&
                  ClipboardQuickSearch.moving(nil, by: 1, in: []) == nil,
                  "方向键应停在有效结果边界")
        let long = String(repeating: "普通内容 ", count: 100) + "我的目标" + String(repeating: " 其他内容", count: 100)
        let snippet = ClipboardQuickSearch.snippet(long, words: ["我的"])
        try check(snippet.contains("我的目标") && snippet.count <= 162 && snippet.hasPrefix("…"),
                  "长文字摘要必须保留实际命中位置并限制长度")
        var unindexed = image
        unindexed.ocrText = nil
        try check(ClipboardQuickSearch.results(in: [unindexed], query: "订单").isEmpty &&
                  ClipboardQuickSearch.results(in: [image], query: "订单").map(\.id) == [image.id],
                  "首次识别完成后，同一图片必须进入搜索结果")
        let scope = ClipboardImageSearchScope(filter: .all, date: nil, tab: .history)
        try check(ClipboardFilterInventory.unrecognizedImages(in: [unindexed, image], scope: scope).map(\.id) == [image.id],
                  "后台识别只应排队未识别的图片")

        try verifyKeys()
        let cancelled = Task.detached { () -> [ClipboardQuickSearchResult] in
            do { try await Task.sleep(for: .seconds(30)) } catch {}
            return ClipboardQuickSearch.results(in: recent, query: "记录")
        }
        cancelled.cancel()
        let cancelledResults = await cancelled.value
        try check(cancelledResults.isEmpty, "取消后的匹配任务不能继续发布旧结果")
        print("Quick search smoke tests passed: text, OCR, source, file, group, ranking, recent items, selection, cancellation and IME-safe keys")
    }

    private static func verifyKeys() throws {
        func action(_ key: Int, _ flags: NSEvent.ModifierFlags = [], input: Bool = true,
                    marked: Bool = false) -> QuickSearchKeyAction? {
            QuickSearchKeyAction.resolve(keyCode: UInt16(key), modifiers: flags,
                                         inputFocused: input, hasMarkedText: marked)
        }
        try check(action(kVK_Return) == .paste && action(kVK_Return, [.command]) == .preview,
                  "回车粘贴、Command 回车预览")
        try check(action(kVK_Space) == nil && action(kVK_Space, input: false) == .preview,
                  "输入框空格正常输入，列表空格才预览")
        try check(action(kVK_ANSI_C, [.command]) == nil &&
                  action(kVK_ANSI_C, [.command], input: false) == .copy &&
                  action(kVK_ANSI_C, [.command, .shift], input: false) == .copyPlainText,
                  "输入框复制仍复制选中的搜索词；列表中才复制历史内容")
        try check(action(kVK_UpArrow) == .previous && action(kVK_DownArrow) == .next &&
                  action(kVK_Escape) == .dismiss && action(kVK_Tab) == .switchFocus &&
                  action(kVK_Tab, [.shift]) == .switchFocus && action(kVK_ANSI_F, [.command]) == .focusSearch,
                  "搜索导航快捷键不完整")
        for key in [kVK_Return, kVK_Escape, kVK_Space, kVK_UpArrow, kVK_DownArrow, kVK_Tab] {
            try check(action(key, marked: true) == nil, "输入法组合文字期间不能截获确认、取消和候选导航")
        }
        try check(action(kVK_Return, [.option]) == nil && action(kVK_ANSI_A) == nil,
                  "不属于搜索操作的按键应交回系统")
    }

    private static func text(_ value: String, time: TimeInterval) -> ClipboardEntry {
        var item = entry(.text, time: time)
        item.text = value
        return item
    }

    private static func entry(_ kind: ClipboardEntry.Kind, time: TimeInterval) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), createdAt: Date(timeIntervalSince1970: time), kind: kind, text: nil,
            imageFileName: nil, imagePasteboardType: nil, digest: UUID().uuidString, byteCount: 1,
            sourceAppName: nil, sourceAppBundleID: nil)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SearchTestError.failed(message) }
    }
}
