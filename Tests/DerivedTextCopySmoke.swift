import AppKit
import Foundation

@MainActor
private final class CopySoundPlayer {
    static let shared = CopySoundPlayer()
    private(set) var plays = 0
    func playIfEnabled() { plays += 1 }
}

@MainActor
private final class MenuBarCopyAnimation {
    private(set) var plays = 0
    func play() { plays += 1 }
}

@MainActor
private final class DerivedTextCopyFixture {
    let store: ClipboardHistoryStore
    let testPasteboard: NSPasteboard
    let menuBarCopyAnimation = MenuBarCopyAnimation()
    var clipboardChanges: ClipboardChangeTracker
    var entries: [ClipboardEntry] = []
    var isPaused = false
    var statusMessage: String?
    var toast: String?
    var refreshes = 0

    init(store: ClipboardHistoryStore, pasteboard: NSPasteboard) {
        self.store = store
        testPasteboard = pasteboard
        clipboardChanges = ClipboardChangeTracker(initialChangeCount: pasteboard.changeCount)
    }
    func refreshStorageSizes(force: Bool) { refreshes += 1 }
    func showToast(_ message: String) { toast = message }

    // INSERT_PRODUCTION_TEXT_COPY_METHODS
}

@main
struct DerivedTextCopySmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookTextCopy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ClipHoookTextCopy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = ClipboardHistoryStore(directory: root, defaults: defaults)
        let fixture = DerivedTextCopyFixture(store: store, pasteboard: board)
        let ocr = "截图识别结果\n保留第二行"
        precondition(fixture.copyScreenshotRecognizedText(ocr), "截图识别文字应复制成功")
        precondition(board.string(forType: .string) == ocr && fixture.entries.first?.text == ocr,
                     "复制后的内容必须同时进入系统剪贴板和历史卡片")
        precondition(fixture.entries.count == 1 && fixture.entries[0].kind == .text,
                     "只复制文字时应只新增文字记录，不能提前保存截图图片")
        let originalID = fixture.entries[0].id
        let observed = fixture.clipboardChanges.observe(changeCount: board.changeCount)
        precondition(!observed.shouldHandle && !observed.shouldNotify,
                     "显式入历史后不能再次被轮询捕获或重复播放提示音")
        precondition(fixture.copyScreenshotRecognizedText(ocr), "重复复制应成功")
        precondition(fixture.entries.count == 1 && fixture.entries[0].id == originalID
                     && fixture.entries[0].copyCount == 2,
                     "重复复制应沿用原有去重和复制次数规则")
        let translated = "Translation result\nKeep this line."
        precondition(fixture.copyTranslatedText(translated), "译文应复制成功")
        precondition(board.string(forType: .string) == translated
                     && fixture.entries.first?.text == translated && fixture.entries.count == 2,
                     "译文也必须在复制后作为独立文字卡片出现在历史中")
        precondition(fixture.toast?.contains("已加入历史") == true && fixture.refreshes == 3,
                     "保存后应更新卡片与存储显示，并反馈已加入历史")
        let reloaded = ClipboardHistoryStore(directory: root, defaults: defaults)
        precondition(reloaded.rootEntries.count == 2 && reloaded.rootEntries.first?.text == translated,
                     "重新读取历史时必须仍能找到复制的识别文字和译文")
        fixture.isPaused = true
        precondition(fixture.copyScreenshotRecognizedText("暂停记录时仍可复制"), "暂停不能阻止复制")
        precondition(board.string(forType: .string) == "暂停记录时仍可复制" && store.rootEntries.count == 2,
                     "暂停记录时不得写入新的历史")
        fixture.isPaused = false
        precondition(!fixture.copyScreenshotRecognizedText(""), "空结果不能报告复制成功")
        _ = fixture.copyProcessedText("既有文本工具结果")
        precondition(store.rootEntries.count == 2, "未请求入历史的其他复制路径不能被本次修改改变")
        precondition(CopySoundPlayer.shared.plays == 5, "每次成功复制只应触发一次提示音")
        precondition(fixture.menuBarCopyAnimation.plays == 5, "每次成功复制只应触发一次菜单栏动效")
        print("Derived text copy smoke passed: pasteboard, OCR/translation history, persistence, deduplication, pause and one-shot feedback")
    }
}
