import AppKit

private enum TextEditorSessionTestError: Error { case failed(String), writeFailed }

// Compiled in the same file as the real editor so its controls can be exercised
// off screen. No screenshot, clipboard contents or visible windows are used.
extension ClipboardTextEditorPanel {
    fileprivate var draftForTest: String { editor.string }
    fileprivate var selectionForTest: NSRange { editor.selectedRange() }
    fileprivate var messageForTest: String { message.stringValue }

    fileprivate func typeForTest(_ text: String, selection: NSRange) {
        editor.string = text
        editor.setSelectedRange(selection)
        textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    }

    fileprivate func markForTest(_ text: String) {
        editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    fileprivate func commitForTest() { save() }
    fileprivate func hasCompositionForTest() -> Bool { editor.hasMarkedText() }
    fileprivate func finishCompositionForTest() { editor.unmarkText() }
    fileprivate func handlesEscapeForTest() -> Bool {
        textView(editor, doCommandBy: #selector(cancelOperation(_:)))
    }
}

@main
struct TextEditorSessionSmoke {
    @MainActor
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let entry = ClipboardEntry(id: UUID(), createdAt: .now, kind: .text,
            text: "original", imageFileName: nil, imagePasteboardType: nil,
            digest: "editor-smoke", byteCount: 8, sourceAppName: nil, sourceAppBundleID: nil)

        var saved: [String] = []
        var closed = 0
        let editor = ClipboardTextEditorPanel(entry: entry, text: "original",
            onSave: { saved.append($0) }, onClose: { closed += 1 })
        let selection = NSRange(location: 2, length: 1)
        editor.typeForTest("unsaved 草稿", selection: selection)
        try check(app.modalWindow == nil, "编辑不应建立应用级模态窗口阻止截图")
        try check(editor.draftForTest == "unsaved 草稿" && editor.selectionForTest == selection,
                  "非模态编辑应保留未保存草稿与光标选择")
        editor.commitForTest()
        try check(saved == ["unsaved 草稿"] && closed == 1,
                  "保存应写入草稿并关闭编辑会话，不依赖 stopModal")
        editor.cancelOperation(nil)
        editor.commitForTest()
        try check(saved.count == 1 && closed == 1, "重复关闭不能重复保存或释放窗口交互")

        let cancelled = ClipboardTextEditorPanel(entry: entry, text: "original",
            onSave: { saved.append($0) }, onClose: { closed += 1 })
        cancelled.typeForTest("discarded", selection: NSRange(location: 4, length: 0))
        cancelled.cancelOperation(nil)
        try check(saved.count == 1 && closed == 2, "取消只关闭编辑，不应写入草稿")

        let windowClose = ClipboardTextEditorPanel(entry: entry, text: "original",
            onSave: { saved.append($0) }, onClose: { closed += 1 })
        windowClose.performClose(nil)
        try check(saved.count == 1 && closed == 3, "窗口关闭按钮应取消编辑并释放交互")

        var shouldFail = true
        let failed = ClipboardTextEditorPanel(entry: entry, text: "original",
            onSave: {
                if shouldFail { throw TextEditorSessionTestError.writeFailed }
                saved.append($0)
            }, onClose: { closed += 1 })
        failed.typeForTest("retry this draft", selection: selection)
        failed.commitForTest()
        try check(closed == 3 && failed.draftForTest == "retry this draft"
                  && failed.messageForTest.hasPrefix("保存失败"),
                  "保存失败应保留编辑会话和草稿，显示原因")
        shouldFail = false
        failed.commitForTest()
        try check(closed == 4 && saved.last == "retry this draft", "失败后的重试应保存同一份草稿")

        let composing = ClipboardTextEditorPanel(entry: entry, text: "original",
            onSave: { saved.append($0) }, onClose: { closed += 1 })
        composing.markForTest("pin yin")
        try check(composing.hasCompositionForTest(), "测试应建立输入法组合状态")
        let savedCount = saved.count
        composing.commitForTest()
        try check(saved.count == savedCount && closed == 4,
                  "拼音候选未确认时，保存不能提交半成品或关闭窗口")
        try check(!composing.handlesEscapeForTest(), "输入法组合期间 Esc 应先交给输入法")
        composing.finishCompositionForTest()
        try check(composing.handlesEscapeForTest() && closed == 5,
                  "组合结束后 Esc 应取消编辑")

        print("Text editor session smoke passed: modeless save/cancel/close, one-shot completion, draft selection, failure retry and IME composition")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TextEditorSessionTestError.failed(message) }
    }
}
