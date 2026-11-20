import AppKit

// VerifyTestBuild inserts the actual selection methods from ShelfView here.
// Only preview presentation is stubbed; no desktop windows or clipboard reads.
@MainActor
private final class ShelfSelectionFixture {
    private struct DisplayedCard {
        let id: String
        let entry: ClipboardEntry
    }
    private enum FocusTarget { case history }
    private var visibleEntries: [DisplayedCard]
    private var selectedID: UUID?
    private var selectedCardKey: String?
    private var selectedIDs: Set<UUID> = []
    private var revealsSelection = true
    private var hasNavigatedHistory = false
    private var detailID: UUID?
    private var focusedTarget: FocusTarget?
    private var resizeScrollTask: Task<Void, Never>?

    init() {
        visibleEntries = (0..<40).map { index in
            let entry = ClipboardEntry(id: UUID(), createdAt: .now, kind: .text,
                text: "Card \(index)", imageFileName: nil, imagePasteboardType: nil,
                digest: "selection-\(index)", byteCount: 8,
                sourceAppName: nil, sourceAppBundleID: nil)
            return DisplayedCard(id: "root-\(entry.id)", entry: entry)
        }
    }
    private func closeDetail() { detailID = nil }
    private func openDetail(_ entry: ClipboardEntry) { detailID = entry.id }
    private func toggleGroup(_ entry: ClipboardEntry) {}

    // PRODUCTION_SELECTION_METHODS

    func verify() {
        // A range selected far from the beginning must keep the current
        // viewport, even if a previous layout scroll is still queued.
        let pending = Task<Void, Never> {}
        resizeScrollTask = pending
        select(visibleEntries[25].entry, cardKey: visibleEntries[25].id, modifiers: [])
        precondition(selectedID == visibleEntries[25].entry.id && selectedIDs.count == 1)
        precondition(!revealsSelection && pending.isCancelled,
                     "鼠标选择必须取消旧的滚动任务并保留当前位置")
        select(visibleEntries[26].entry, cardKey: visibleEntries[26].id, modifiers: .shift)
        precondition(selectedIDs == Set([25, 26].map { visibleEntries[$0].entry.id }) &&
                     selectedCardKey == visibleEntries[26].id && !revealsSelection,
                     "Shift 选择右侧卡片应保留两项选择，但不能发起自动滚动")
        select(visibleEntries[23].entry, cardKey: visibleEntries[23].id, modifiers: .shift)
        precondition(selectedIDs == Set((23...26).map { visibleEntries[$0].entry.id }) && !revealsSelection,
                     "反向范围选择也应保持当前位置")
        moveSelection(by: 1)
        precondition(selectedCardKey == visibleEntries[24].id && selectedIDs.count == 1 && revealsSelection,
                     "范围选择之后使用键盘仍须跟随到当前卡片")
        select(visibleEntries[24].entry, cardKey: visibleEntries[24].id, modifiers: [])
        moveSelection(by: 0)
        precondition(revealsSelection, "键盘选中同一卡片时也应恢复滚动跟随")
        select(visibleEntries[28].entry, cardKey: visibleEntries[28].id, modifiers: .command)
        precondition(selectedIDs.count == 2 && !revealsSelection,
                     "Command 离散多选不能改变视口")
        select(visibleEntries[28].entry, cardKey: visibleEntries[28].id, modifiers: .command)
        precondition(selectedIDs == [visibleEntries[24].entry.id] && !revealsSelection,
                     "鼠标取消选中时不能滚到剩余卡片")
        selectForContextMenu(visibleEntries[30].entry, cardKey: visibleEntries[30].id)
        precondition(selectedIDs == [visibleEntries[30].entry.id] && !revealsSelection,
                     "右键选择应保持菜单所在视口")
    }
}

@main
struct ShelfSelectionSmoke {
    @MainActor static func main() {
        ShelfSelectionFixture().verify()
        print("Shelf selection smoke passed: pointer viewport preservation, pending scroll cancellation, bidirectional Shift ranges, Command toggling, context selection and keyboard follow (selection logic; SwiftUI scrolling requires desktop validation)")
    }
}
