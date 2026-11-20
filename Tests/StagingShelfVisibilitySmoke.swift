import AppKit
import ObjectiveC

// Appended to the production controller by VerifyTestBuild so the fixture can
// drive its real cleanup paths without displaying desktop windows or starting
// global input monitors. Only the native panel's presentation is replaced.
private final class StagingVisibilityPanel: StagingShelfPanel {
    private var shown = true
    private(set) var frontCalls = 0
    private(set) var hideCalls = 0
    override var isVisible: Bool { shown }
    override func orderFrontRegardless() { shown = true; frontCalls += 1 }
    override func orderOut(_ sender: Any?) { shown = false; hideCalls += 1 }
}

private final class StagingPreviewVisibilityPanel: StagingShelfPreviewPanel {
    private var shown = true
    override var isVisible: Bool { shown }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
}

private final class StagingNativeSessionFixture: NSDraggingSession {
    private var animatesBack = true
    override var animatesToStartingPositionsOnCancelOrFail: Bool {
        get { animatesBack }
        set { animatesBack = newValue }
    }
}

private final class StagingPanFixture: ContentDragGestureRecognizer {
    var currentState: NSGestureRecognizer.State = .began
    private var fixtureEnabled = true
    private(set) var cancellations = 0
    override var state: NSGestureRecognizer.State {
        get { currentState }
        set { currentState = newValue }
    }
    override var isEnabled: Bool {
        get { fixtureEnabled }
        set {
            if !newValue && fixtureEnabled { currentState = .cancelled; cancellations += 1 }
            fixtureEnabled = newValue
        }
    }
    override func location(in view: NSView?) -> NSPoint { NSPoint(x: 24, y: 24) }
}

private final class StagingGestureSourceFixture: StagingShelfDragView {
    var session: NSDraggingSession!
    var refusesStart = false
    var endsDuringStart = false
    private(set) var gestureStarts = 0
    private(set) var eventStarts = 0
    private(set) var receivedGesture: NSGestureRecognizer?
    override func prepareExportKeyboardFocus() {} // Never activate a desktop app in this fixture.
    override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent,
                                       source: any NSDraggingSource) -> NSDraggingSession {
        eventStarts += 1
        return session
    }
    @available(macOS 27.0, *)
    override func beginDraggingSession(items: [NSDraggingItem], gesture: NSGestureRecognizer,
                                       source: any NSDraggingSource) -> NSDraggingSession? {
        gestureStarts += 1
        receivedGesture = gesture
        if refusesStart { return nil }
        draggingSession(session, willBeginAt: .zero)
        if endsDuringStart { draggingSession(session, endedAt: .zero, operation: []) }
        return session
    }
}

extension StagingShelfDragView {
    fileprivate func attachGestureFixture(_ gesture: ContentDragGestureRecognizer) {
        if let exportGesture { removeGestureRecognizer(exportGesture) }
        exportGesture = gesture
        gesture.delegate = self
        addGestureRecognizer(gesture)
    }
    fileprivate func startGestureFixture(_ gesture: ContentDragGestureRecognizer, event: NSEvent) {
        gesture.mouseDown(with: event)
        handleExportGesture(gesture)
        let point = NSPoint(x: event.locationInWindow.x + 12, y: event.locationInWindow.y)
        let moved = NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [],
            timestamp: 0.01, windowNumber: event.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 1)!
        gesture.mouseDragged(with: moved)
        handleExportGesture(gesture)
    }
}

@MainActor
private final class StagingDropFixture: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ board: NSPasteboard) { draggingPasteboard = board }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

extension StagingShelfController {
    fileprivate func attachVisibilityFixture(_ panel: StagingVisibilityPanel) {
        self.panel = panel
        let content = StagingShelfView(controller: self)
        panel.contentView = content
        body = content
        manual = false
    }
    fileprivate func finishVisibilityFixture() { finishObservedDrag() }
    fileprivate func hoverVisibilityFixture() { body?.isTargeted = true }
    fileprivate func mouseUpVisibilityFixture() { finishObservedDrag(preservingTargetedDrop: true) }
    fileprivate func checkScrollingFixture() throws { try body?.checkScrollingFixture() }
    fileprivate func selectedPreviewFixture() throws -> StagingShelfPreviewPayload? { try selectedPreviewPayload() }
    fileprivate func attachPreviewFixture(_ preview: StagingShelfPreviewController) { previewController = preview }
    fileprivate func checkDropOverItemFixture(_ board: NSPasteboard) throws {
        try body?.checkDropOverItemFixture(board)
    }
    fileprivate func prepareExportFixture(ids: Set<UUID>) throws {
        exportPayload = try store.dragPayload(ids: ids)
        exportedIDs = ids
        exportReturnFrame = panel?.frame
        exportEscapeRequested = false
        installExportEscapeMonitor()
        exportStarted()
    }
    fileprivate var hasNativeExportSessionFixture: Bool { exportSession != nil }
    fileprivate var hasExportTokenFixture: Bool { exportToken != nil }
    fileprivate func escapeExportFixture() { observe(StagingShelfVisibilitySmoke.key(53)) }
    fileprivate var hasExportEscapeObserverFixture: Bool { exportEscapeMonitor != nil }
    fileprivate func expandButtonFixture() { body?.expandButtonFixture(); finishAppearance() }

    fileprivate func checkAppearanceFixture() throws {
        guard let panel, let body else { throw StagingShelfVisibilitySmoke.Failure.failed("动画测试缺少面板") }
        func pauseDriver() {
            appearanceDisplayLink?.invalidate()
            appearanceDisplayLink = nil
        }
        func sample(_ fraction: Double) {
            guard let motion = appearanceMotion else { return }
            advanceAppearance(at: appearanceStartedAt + motion.duration * fraction)
        }
        func check(_ value: Bool, _ message: String) throws { try StagingShelfVisibilitySmoke.check(value, message) }
        let fullFrame = panel.frame
        let ids = store.items.map(\.id)
        let selection = selected
        collapse()
        pauseDriver()
        try check(isCollapsed && appearanceMotion != nil && panel.frame == fullFrame && panel.alphaValue == 1,
                  "收起请求不能立刻缩成窄条，第一帧须保留完整面板")
        sample(0.4)
        try check(panel.frame.size == fullFrame.size && panel.alphaValue > 0 && panel.alphaValue < 1 && !body.collapsedLayoutFixture,
                  "收起前半程须侧移淡出完整内容，不挤压或提前隐藏文件")
        let midFrame = panel.frame, midAlpha = panel.alphaValue
        expand()
        pauseDriver()
        try check(appearanceMotion?.from.frame == midFrame && appearanceMotion?.from.opacity == midAlpha &&
                  panel.frame == midFrame && expandedFrame == fullFrame,
                  "收起中途展开必须衔接当前透明度和位置，保留完整原始尺寸")
        sample(1.01)
        try check(!isCollapsed && panel.frame == fullFrame && panel.alphaValue == 1 &&
                  appearanceMotion == nil && appearanceDisplayLink == nil && expandedFrame == nil,
                  "反向展开完成后恢复原位置与透明度并停止逐帧回调")

        collapse(); pauseDriver(); sample(0.85)
        try check(body.collapsedLayoutFixture && panel.frame.width == 18 && panel.alphaValue > 0 && panel.alphaValue < 1,
                  "文件内容淡出后才显示淡入的侧边标签")
        expand(); pauseDriver(); sample(0.6)
        try check(!body.collapsedLayoutFixture && panel.frame.size == fullFrame.size,
                  "展开后半程以完整尺寸淡入，不拉伸文件内容")
        collapse(); pauseDriver(); sample(1.01)
        try check(isCollapsed && body.collapsedLayoutFixture && panel.frame.size == NSSize(width: 18, height: 84) &&
                  expandedFrame == fullFrame && panel.alphaValue == 1,
                  "展开中再次收起，最终标签与原面板尺寸不能错乱")
        body.expandButtonFixture(); pauseDriver(); sample(1.01)
        try check(panel.frame == fullFrame && !isCollapsed && panel.alphaValue == 1,
                  "标签点击走同一条展开动画，恢复完整内容")

        collapse(); pauseDriver(); sample(0.4)
        beginScreenshotInteraction()
        try check(isCollapsed && body.collapsedLayoutFixture && panel.alphaValue == 1 && appearanceMotion == nil,
                  "动画中开始截图须稳定为目标标签，不能截到半透明中间帧")
        endScreenshotInteraction()
        expand(); pauseDriver(); sample(0.5)
        beginScreenshotInteraction()
        try check(!isCollapsed && panel.frame == fullFrame && panel.alphaValue == 1 && appearanceMotion == nil,
                  "展开过程中截图须稳定为完整面板，不能丢失内容")
        endScreenshotInteraction()

        let dropBoard = NSPasteboard.withUniqueName()
        defer { dropBoard.releaseGlobally() }
        dropBoard.setString("动画期间的新投放", forType: .string)
        collapse(); pauseDriver(); sample(0.3)
        try check(incomingDragOperation(dropBoard) == .copy && !isCollapsed &&
                  panel.frame == fullFrame && panel.alphaValue == 1 && appearanceMotion == nil,
                  "拖入时须立即落在完整接收区域，不能让动画移走原生投放目标")
        try check(receive(dropBoard) && store.items.count == ids.count + 1 && !panel.ignoresMouseEvents,
                  "动画被投放打断后仍可追加内容并保持交互")
        incomingDragEnded()
        try check(ids.allSatisfy { id in store.items.contains { $0.id == id } } && selected == selection,
                  "动画和投放不应丢失原内容或选择")

        collapse(); pauseDriver(); sample(0.4)
        hide()
        advanceAppearance(at: CACurrentMediaTime() + 10)
        try check(!panel.isVisible && panel.frame == fullFrame && panel.alphaValue == 1 &&
                  appearanceMotion == nil && appearanceDisplayLink == nil && !isCollapsed,
                  "中途关闭必须取消动画，迟到回调不能重新显示窗口或留下透明状态")
        present(on: panel.screen ?? NSScreen.screens[0], pointer: NSPoint(x: fullFrame.midX, y: fullFrame.midY))
        collapse(); pauseDriver(); sample(0.4)
        present(on: panel.screen ?? NSScreen.screens[0])
        try check(panel.isVisible && !isCollapsed && panel.alphaValue == 1 && appearanceMotion == nil &&
                  panel.frame.size == fullFrame.size,
                  "重新唤起必须清理旧动画，恢复完整正常面板")
        collapse(); pauseDriver(); sample(0.5)
        remove(Set(store.items.map(\.id)))
        advanceAppearance(at: CACurrentMediaTime() + 10)
        try check(!panel.isVisible && store.items.isEmpty && appearanceDisplayLink == nil,
                  "动画中移除最后一项后仍须自动隐藏空箱且停止回调")
    }
}

extension StagingShelfPreviewController {
    fileprivate func attachPreviewFixture(_ panel: StagingPreviewVisibilityPanel) {
        self.panel = panel
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.delegate = self
    }
    fileprivate var previewTextFixture: String? {
        ((panel?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string
    }
}

extension StagingShelfRow {
    fileprivate func checkTileLayoutFixture() throws {
        layoutSubtreeIfNeeded()
        try StagingShelfVisibilitySmoke.check(artwork.frame.size == NSSize(width: 64, height: 64),
            "缩略图须从 36 点增大为 64 点")
        try StagingShelfVisibilitySmoke.check(title.frame.maxY < artwork.frame.minY && title.maximumNumberOfLines == 1,
            "文件名应在图标下方单行显示，允许截断")
        try StagingShelfVisibilitySmoke.check(removeButton.isHidden, "移除按钮默认隐藏")
        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        mouseEntered(with: enter)
        try StagingShelfVisibilitySmoke.check(!removeButton.isHidden, "鼠标悬停文件时才显示叉号")
        let removePoint = convert(NSPoint(x: removeButton.frame.midX, y: removeButton.frame.midY), to: superview)
        let hit = hitTest(removePoint)
        try StagingShelfVisibilitySmoke.check(hit === removeButton || hit?.isDescendant(of: removeButton) == true,
            "放大缩略图后，单项移除按钮仍须能单独点击")
        mouseExited(with: enter)
        try StagingShelfVisibilitySmoke.check(removeButton.isHidden, "离开文件后叉号再次隐藏")
        updateTrackingAreas()
        try StagingShelfVisibilitySmoke.check(hoverArea?.options.contains(.inVisibleRect) == true,
            "滚动后的悬停命中应跟随可见区域")
    }

    fileprivate func checkIncomingDropFixture(_ board: NSPasteboard) throws {
        let sender = StagingDropFixture(board)
        // The actual image and filename must both resolve to this native drop
        // destination, rather than a child image/label or the underlying app.
        for view in [artwork as NSView, title] {
            let point = convert(NSPoint(x: view.frame.midX, y: view.frame.midY), to: superview)
            try StagingShelfVisibilitySmoke.check(hitTest(point) === self,
                "缩略图和文件名必须都命中可投放的文件行")
            try StagingShelfVisibilitySmoke.check(draggingEntered(sender) == .copy && prepareForDragOperation(sender),
                "已有文件上必须能接收新的投放")
        }
        try StagingShelfVisibilitySmoke.check(performDragOperation(sender), "文件行实际投放必须成功")
        draggingEnded(sender)
    }
}

extension StagingShelfView {
    fileprivate var collapsedLayoutFixture: Bool { collapsed }
    fileprivate func expandButtonFixture() { edgeButton.performClick(nil) }
    fileprivate func checkDropOverItemFixture(_ board: NSPasteboard) throws {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try rows.first?.checkIncomingDropFixture(board)
    }

    fileprivate func checkScrollingFixture() throws {
        layoutSubtreeIfNeeded()
        try StagingShelfVisibilitySmoke.check(!scroll.isHidden && scroll.hasVerticalScroller && rows.count == 30,
            "全部文件应直接进入竖向滚动列表，无需展开")
        try StagingShelfVisibilitySmoke.check(document.isFlipped && document.bounds.height > scroll.contentSize.height,
            "列表从首项开始，超出窗口的内容须可滚动")
        guard let first = rows.first, let last = rows.last else { throw StagingShelfVisibilitySmoke.Failure.failed("列表缺少文件") }
        try first.checkTileLayoutFixture()
        try StagingShelfVisibilitySmoke.check(rows[1].frame.minX == first.frame.minX && rows[1].frame.minY > first.frame.maxY,
            "内容应窄版单列排列，文件名下置")
        try StagingShelfVisibilitySmoke.check(subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.count == 2,
            "标题栏只保留清空和关闭，移除全选按钮")
        try StagingShelfVisibilitySmoke.check(first.frame.minY == 0 && last.frame.maxY <= document.bounds.height,
            "所有暂存项均应排在文档范围内，不限制可显示数量")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: last.frame.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try StagingShelfVisibilitySmoke.check(scroll.documentVisibleRect.intersects(last.frame),
            "滚动到底部必须能看到最后一项")
        let point = NSPoint(x: last.frame.minX + 25, y: last.frame.midY)
        try StagingShelfVisibilitySmoke.check(last.hitTest(point) === last,
            "底部文件图标也须命中对应拖动行，而不是背景")
        let size = frame.size
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        mouseUp(with: click)
        try StagingShelfVisibilitySmoke.check(frame.size == size && !scroll.isHidden,
            "点击标题或空白区域不能把列表折叠")
    }
}

@main
struct StagingShelfVisibilitySmoke {
    enum Failure: Error { case failed(String) }
    @MainActor private static let dragSession = StagingNativeSessionFixture()

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipHoookStagingVisibility-\(UUID())")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        func makeFixture(_ name: String) -> (StagingShelfController, StagingVisibilityPanel) {
            let controller = StagingShelfController(store: StagingShelfStore(directory: root.appendingPathComponent(name)))
            let panel = StagingVisibilityPanel(contentRect: NSRect(origin: NSPoint(x: 40, y: 60), size: StagingShelfPlacement.defaultSize),
                styleMask: StagingShelfPanel.sourceStyleMask, backing: .buffered, defer: true)
            panel.level = NSWindow.Level(rawValue: PanelLayout.shelfWindowLevel + 2)
            controller.attachVisibilityFixture(panel)
            return (controller, panel)
        }
        let (late, latePanel) = makeFixture("late")
        let initialFrame = latePanel.frame
        // Reproduce CoreDrag delivering mouse-up cleanup before the drop commits.
        late.finishVisibilityFixture()
        try check(!latePanel.isVisible, "未投放的空箱仍可在拖动结束时收起")
        board.clearContents()
        board.setString("成功投放后保持显示", forType: .string)
        try check(late.receive(board), "有效内容应成功投放")
        try check(latePanel.isVisible, "松手收起先执行时，成功投放必须重新显示暂存箱")
        try check(latePanel.frame == initialFrame, "投放后应留在原位置，不重新计算屏幕位置")
        late.finishVisibilityFixture()
        try check(latePanel.isVisible, "成功投放后，延迟拖动结束回调不能收起窗口")
        let ids = Set(late.store.items.map(\.id))
        _ = try late.store.dragPayload(ids: ids)
        late.finishVisibilityFixture()
        try check(latePanel.isVisible && late.store.items.count == 1, "再次拖动或取消不应收起已有内容")
        late.hide()
        late.finishVisibilityFixture()
        try check(!latePanel.isVisible && late.store.items.count == 1, "主动隐藏仍应生效，并保留暂存内容")

        let (normal, normalPanel) = makeFixture("normal")
        normal.hoverVisibilityFixture()
        normal.mouseUpVisibilityFixture()
        try check(normalPanel.isVisible && normalPanel.hideCalls == 0,
                  "松手时仍是投放目标，不能先收起或清除目标状态，避免闪退和拒绝投放")
        try check(normal.receive(board), "正常回调顺序应能投放")
        normal.incomingDragEnded()
        try check(normalPanel.isVisible, "正常回调顺序也应保持显示")
        try check(normal.receive(board) && normal.store.items.count == 1, "重复投放应去重并保持显示")
        normal.finishVisibilityFixture()
        try check(normalPanel.isVisible, "重复内容投放后不能收起")
        normal.remove(Set(normal.store.items.map(\.id)))
        try check(!normalPanel.isVisible && normal.store.items.isEmpty, "移除最后一项后必须自动收起，不受之前手动保留状态影响")
        normal.finishVisibilityFixture()
        try check(!normalPanel.isVisible, "清空后的延迟拖动结束回调不能重开空箱")
        let (cancelled, cancelledPanel) = makeFixture("cancelled")
        cancelled.hoverVisibilityFixture()
        cancelled.mouseUpVisibilityFixture()
        cancelled.incomingDragEnded()
        try check(!cancelledPanel.isVisible, "没有成功投放的自动空箱在系统拖动取消后仍应收起")

        let (list, listPanel) = makeFixture("list")
        board.clearContents()
        try check(board.writeObjects((0..<30).map { index in
            let item = NSPasteboardItem()
            item.setString("暂存项 \(index)", forType: .string)
            return item
        }), "长列表测试数据未写入")
        try check(list.receive(board), "整批项目应能投放")
        try list.checkScrollingFixture()
        list.finishVisibilityFixture()
        try check(listPanel.isVisible && list.store.items.count == 30 && listPanel.frame.size == NSSize(width: 156, height: 360),
                  "长列表投放后保持显示，窗口高度不随数量或拖动回调跳变")

        // Drop onto an existing row after scrolling; it must append using the
        // sender's actual pasteboard, not the public drag pasteboard.
        board.clearContents()
        board.setString("覆盖在已有文件上的新内容", forType: .string)
        try list.checkDropOverItemFixture(board)
        try check(list.store.items.count == 31 && listPanel.isVisible,
                  "覆盖文件投放后只新增一项，重复投放去重，暂存箱不收起")

        let firstID = list.store.items[0].id, secondID = list.store.items[1].id
        list.select(firstID, modifiers: [])
        list.select(secondID, modifiers: .command)
        guard let selectedPayload = try list.selectedPreviewFixture() else { throw Failure.failed("选中项预览为空") }
        try check(selectedPayload.id == secondID, "多选时应预览最后点击的项")
        let preview = StagingShelfPreviewController()
        let previewPanel = StagingPreviewVisibilityPanel(contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        previewPanel.level = NSWindow.Level(rawValue: PanelLayout.shelfWindowLevel + 3)
        preview.attachPreviewFixture(previewPanel)
        list.attachPreviewFixture(preview)
        preview.setContent(selectedPayload)
        try check(preview.isVisible && preview.previewTextFixture == "暂存项 1", "文字预览应显示完整选中内容")
        list.select(firstID, modifiers: [])
        try check(preview.previewTextFixture == "暂存项 0", "预览打开时改变选择应更新内容")
        listPanel.level = NSWindow.Level(rawValue: PanelLayout.shelfWindowLevel + 2)
        let level = listPanel.level, previewLevel = previewPanel.level
        let hides = listPanel.hideCalls, frame = listPanel.frame
        list.beginScreenshotInteraction()
        list.beginScreenshotInteraction()
        try check(listPanel.isVisible && previewPanel.isVisible && listPanel.hideCalls == hides && listPanel.frame == frame,
                  "截图开始时暂存箱与预览不能隐藏、移动或清空")
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        try check(listPanel.level.rawValue > dockLevel && previewPanel.level.rawValue > dockLevel &&
                  listPanel.level.rawValue < NSWindow.Level.popUpMenu.rawValue &&
                  previewPanel.level.rawValue < NSWindow.Level.popUpMenu.rawValue,
                  "截图期间暂存箱及预览应在 Dock 上方、标注层下方，不能露出 Dock 或挡住截图输入")
        list.endScreenshotInteraction()
        list.endScreenshotInteraction()
        try check(listPanel.level == level && previewPanel.level == previewLevel && listPanel.isVisible,
                  "截图完成、取消或失败后应恢复窗口层级，重复收尾不能改变层级")
        list.collapse(animated: false)
        try check(list.isCollapsed && listPanel.isVisible && listPanel.frame.width == 18 && listPanel.frame.height == 84,
                  "侧滑收起后必须留一个窄边缘，不能隐藏整个暂存箱")
        try check(!preview.isVisible && list.store.items.count == 31,
                  "收起时关闭预览，保留暂存项目和选择")
        let edgeFrame = listPanel.frame
        list.beginScreenshotInteraction(); list.endScreenshotInteraction()
        try check(listPanel.frame == edgeFrame && list.isCollapsed && listPanel.isVisible,
                  "截图开始和结束不能展开、移走或隐藏侧边标签")
        list.expandButtonFixture()
        try check(!list.isCollapsed && listPanel.frame == frame && listPanel.isVisible,
                  "点击侧边标签必须还原原来的完整位置和尺寸")
        previewPanel.orderFrontRegardless()
        preview.setContent(selectedPayload)
        let escape = key(53)
        try check(list.handleKey(escape) && !preview.isVisible && listPanel.isVisible,
                  "Esc 须先关闭预览，并保留非空暂存箱")
        previewPanel.orderFrontRegardless()
        preview.setContent(selectedPayload)
        try check(list.handleKey(key(49)) && !preview.isVisible && listPanel.isVisible,
                  "再次按空格只关闭预览")
        previewPanel.orderFrontRegardless()
        preview.setContent(selectedPayload)
        previewPanel.sendEvent(key(49))
        try check(!preview.isVisible && listPanel.isVisible, "预览窗口获得焦点时，空格也应关闭预览")
        previewPanel.orderFrontRegardless()
        preview.setContent(selectedPayload)
        list.remove(Set(list.store.items.map(\.id)))
        try check(!preview.isVisible && !listPanel.isVisible && list.store.items.isEmpty,
                  "清空时同时关闭预览和空箱，不能遗留旧内容或访问权")

        let (animated, _) = makeFixture("animated")
        board.clearContents()
        board.setString("动画测试内容", forType: .string)
        try check(animated.receive(board), "动画测试内容应能暂存")
        animated.selectAll()
        try animated.checkAppearanceFixture()

        if #available(macOS 27.0, *) {
            let (gestures, gesturePanel) = makeFixture("gesture")
            try checkNativeGestureExport(gestures, panel: gesturePanel, board: board)
            let (input, _) = makeFixture("window-input")
            try checkWindowGestureInput(input, board: board)
        }

        let (outgoing, outgoingPanel) = makeFixture("outgoing")
        board.clearContents()
        try check(board.writeObjects((0..<3).map { index in
            let value = NSPasteboardItem(); value.setString("取出项 \(index)", forType: .string); return value
        }), "拖出测试数据未写入")
        try check(outgoing.receive(board), "拖出前应成功暂存")
        let outgoingIDs = outgoing.store.items.map(\.id)
        let dragSource = StagingShelfDragView(frame: .zero)
        dragSource.controller = outgoing
        let originalExportFrame = outgoingPanel.frame
        try check(!outgoingPanel.styleMask.contains(.nonactivatingPanel) && outgoingPanel.canBecomeKey,
                  "暂存箱点击时必须正常获取键盘焦点，不能作为不激活应用的拖动源")
        try outgoing.prepareExportFixture(ids: [outgoingIDs[0], outgoingIDs[1]])
        try check(outgoingPanel.alphaValue == 1 && outgoingPanel.frame == originalExportFrame,
                  "原生拖动开始回调不能把源窗口设成全透明或立即修改源坐标")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        try check(outgoingPanel.isVisible && outgoingPanel.alphaValue == 1 && !outgoingPanel.ignoresMouseEvents &&
                  outgoingPanel.frame == originalExportFrame,
                  "原生跟踪循环运行后，暂存箱仍须留在原位置接收输入，不能有延迟的移出屏幕回调")
        try check(dragSource.draggingSession(dragSession, sourceOperationMaskFor: .outsideApplication) == .copy,
                  "正常拖出仍须允许目标应用复制接收")
        outgoing.exportEnded(operation: [])
        try check(outgoing.store.items.count == 3 && outgoingPanel.isVisible && outgoingPanel.alphaValue == 1
                  && !outgoingPanel.ignoresMouseEvents && outgoingPanel.frame == originalExportFrame,
                  "目标拒收时全部保留，在原位置恢复可交互的暂存箱")
        try outgoing.prepareExportFixture(ids: [outgoingIDs[0], outgoingIDs[1]])
        try check(outgoing.trackExportKey(escape) === escape,
                  "Esc 必须原样返回给 AppKit，不能被吞掉、预留为快捷键或替换成重新构造的事件")
        outgoing.escapeExportFixture()
        try check(dragSource.draggingSession(dragSession, sourceOperationMaskFor: .outsideApplication) == .copy &&
                  dragSource.draggingSession(dragSession, sourceOperationMaskFor: .withinApplication) == .copy,
                  "Esc 观察器不能改写尚未结束的系统会话；取消须由 CoreDrag 处理原按键并报告最终结果")
        outgoing.exportEnded(operation: [])
        try check(outgoing.store.items.count == 3 && outgoingPanel.isVisible,
                  "系统确认取消后须保留拖出项目并恢复暂存箱")
        try check(!outgoing.hasExportEscapeObserverFixture &&
                  outgoingPanel.alphaValue == 1 && !outgoingPanel.ignoresMouseEvents && outgoingPanel.frame == originalExportFrame,
                  "结束拖动必须移除被动监听，恢复原位置、透明度与交互")
        try outgoing.prepareExportFixture(ids: [outgoingIDs[0]])
        try check(outgoing.trackExportKey(key(8)).keyCode == 8 && outgoing.exportOperationMask == .copy,
                  "其他按键须原样保留且不能取消原生拖动")
        _ = outgoing.trackExportKey(escape)
        _ = outgoing.trackExportKey(escape)
        try check(outgoingPanel.frame == originalExportFrame && outgoing.exportOperationMask == .copy,
                  "重复 Esc 不能移走源窗口，也不能伪造原生会话已结束")
        outgoing.exportEnded(operation: [])
        try check(outgoing.store.items.count == 3 && outgoingPanel.isVisible,
                  "重复 Esc 后系统确认取消，不能移除暂存内容")
        try outgoing.prepareExportFixture(ids: [outgoingIDs[1]])
        try check(!outgoing.handleKey(key(53)) && outgoing.exportOperationMask == .copy,
                  "响应链收到 Esc 也须继续交给原生拖动处理，不能自行宣布取消成功")
        outgoing.exportEnded(operation: [])
        for _ in 0..<20 {
            try outgoing.prepareExportFixture(ids: [outgoingIDs[0]])
            _ = outgoing.trackExportKey(escape)
            outgoing.exportEnded(operation: [])
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            try check(outgoingPanel.frame == originalExportFrame && outgoingPanel.isVisible &&
                      outgoingPanel.alphaValue == 1 && !outgoingPanel.ignoresMouseEvents &&
                      !outgoing.hasExportEscapeObserverFixture && outgoing.store.items.count == 3,
                      "连续取消后源窗口、监听和暂存内容必须完整恢复，不能留下影响下一轮的状态")
        }
        try outgoing.prepareExportFixture(ids: [outgoingIDs[0], outgoingIDs[1]])
        try check(outgoing.exportOperationMask == .copy, "下一轮拖动必须恢复复制能力")
        outgoing.select(outgoingIDs[2], modifiers: [])
        _ = outgoing.trackExportKey(escape)
        outgoing.exportEnded(operation: .copy)
        try check(outgoing.store.items.map(\.id) == [outgoingIDs[2]] && outgoingPanel.isVisible,
                  "即使先观察到 Esc，只要系统最终确认成功，仍须移除实际拖出的项目；不能误删后来选中的其他项目")
        try outgoing.prepareExportFixture(ids: [outgoingIDs[2]])
        outgoing.exportEnded(operation: .copy)
        try check(outgoing.store.items.isEmpty && !outgoingPanel.isVisible,
                  "成功取出最后一项后自动隐藏空箱")
        try check(StagingShelfStore(directory: root.appendingPathComponent("outgoing")).items.isEmpty,
                  "成功取出必须持久化移除，重启后不重新出现")
        try check(outgoing.exportOperationMask.isEmpty, "拖动结束后拖动源不能继续提供内容")
        outgoing.exportEnded(operation: .copy)
        try check(outgoing.store.items.isEmpty && !outgoingPanel.isVisible,
                  "重复结束回调不能再次移除内容、重新显示面板或恢复旧的拖动状态")
        print("Staging shelf visibility smoke passed: activating click focus, stable visible native drag source across tracking turns, 20 cancellation cleanup cycles, authoritative completion after Escape requests, original Escape pass-through, operation masks, reversible slide/fade, interrupted animation cleanup, stable drop/screenshot, native row drop, preview routing, accepted export removal, confirmed cancellation/refusal preservation and empty cleanup (offscreen; physical key cancellation requires desktop validation)")
    }

    @MainActor @available(macOS 27.0, *)
    private static func checkNativeGestureExport(_ controller: StagingShelfController,
                                                panel: StagingVisibilityPanel, board: NSPasteboard) throws {
        board.clearContents()
        board.setString("手势拖动测试", forType: .string)
        try check(controller.receive(board), "手势测试须先暂存内容")
        let id = controller.store.items[0].id
        let source = StagingGestureSourceFixture(frame: NSRect(x: 12, y: 60, width: 100, height: 100))
        source.controller = controller
        source.itemID = id
        source.session = dragSession
        panel.contentView?.addSubview(source)
        let pan = StagingPanFixture()
        source.attachGestureFixture(pan)
        let location = source.convert(NSPoint(x: 24, y: 24), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        try check(source.gestureRecognizer(pan, shouldAttemptToRecognizeWith: event),
                  "实际命中的暂存项须允许手势开始")
        let child = NSButton(frame: NSRect(x: 15, y: 15, width: 30, height: 30))
        source.addSubview(child)
        try check(!source.gestureRecognizer(pan, shouldAttemptToRecognizeWith: event),
                  "子按钮命中时不能启动拖动或抢走点击")
        child.removeFromSuperview()
        source.startGestureFixture(pan, event: event)
        try check(source.gestureStarts == 1 && source.eventStarts == 0 && source.receivedGesture === pan &&
                  controller.isExporting && controller.hasNativeExportSessionFixture,
                  "macOS 27 须用实际手势启动原生拖动并保留会话，不能回到旧事件入口")
        let escape = key(53)
        pan.currentState = .possible
        pan.reset()
        try check(controller.trackExportKey(escape) === escape && pan.cancellations == 0 && pan.isEnabled &&
                  controller.isExporting && controller.store.items.count == 1,
                  "系统已重置手势后 Esc 须透传，原生结束回调前不能伪造结束或移除项目")
        _ = controller.trackExportKey(escape)
        try check(pan.cancellations == 0, "重复 Esc 不应反复切换已交接的输入手势")
        source.draggingSession(dragSession, endedAt: .zero, operation: [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        try check(!controller.isExporting && !controller.hasNativeExportSessionFixture && !controller.hasExportTokenFixture &&
                  pan.isEnabled && controller.store.items.count == 1,
                  "系统确认取消后须释放会话和标记、恢复手势并保留内容")
        pan.currentState = .began
        source.refusesStart = true
        source.startGestureFixture(pan, event: event)
        try check(!controller.isExporting && !controller.hasNativeExportSessionFixture && !controller.hasExportTokenFixture,
                  "新接口返回 nil 时须收尾，不能遗留正在拖出的状态")
        source.refusesStart = false
        source.endsDuringStart = true
        source.startGestureFixture(pan, event: event)
        try check(!controller.isExporting && !controller.hasNativeExportSessionFixture && !controller.hasExportTokenFixture,
                  "原生跟踪在启动调用返回前已结束时，不能重新保存过期会话")
        source.endsDuringStart = false
        source.startGestureFixture(pan, event: event)
        source.draggingSession(dragSession, endedAt: .zero, operation: .copy)
        try check(controller.store.items.isEmpty && !controller.hasNativeExportSessionFixture,
                  "下一轮正常手势投放仍须成功移除暂存项")
        print("Native gesture source smoke passed: gesture entry, button hit filtering, reset-before-Escape handoff, native completion authority, session lifetime, nil start and synchronous end cleanup (offscreen)")
    }

    @MainActor @available(macOS 27.0, *)
    private static func checkWindowGestureInput(_ controller: StagingShelfController, board: NSPasteboard) throws {
        for selector in [#selector(NSResponder.mouseDown(with:)), #selector(NSResponder.mouseDragged(with:)),
                         #selector(NSResponder.mouseUp(with:))] {
            let implementation = class_getMethodImplementation(StagingShelfDragView.self, selector)!
            let inherited = class_getMethodImplementation(NSView.self, selector)!
            try check(unsafeBitCast(implementation, to: UnsafeRawPointer.self) ==
                      unsafeBitCast(inherited, to: UnsafeRawPointer.self),
                      "暂存箱输入不能混用旧视图鼠标重载与新手势")
        }
        board.clearContents()
        board.setString("真实窗口事件分发测试", forType: .string)
        try check(controller.receive(board), "窗口输入测试须先暂存内容")
        let window = NSPanel(contentRect: NSRect(x: -100000, y: -100000, width: 200, height: 160),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        let source = StagingGestureSourceFixture(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        source.controller = controller
        source.itemID = controller.store.items[0].id
        source.session = dragSession
        window.contentView = source
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let gesture = source.gestureRecognizers.compactMap { $0 as? ContentDragGestureRecognizer }.first!
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged].enumerated() {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 24 + 16 * index, y: 24),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try check(source.gestureStarts == 1 && source.eventStarts == 0 && source.receivedGesture === gesture &&
                  controller.isExporting, "经 AppKit 窗口分发的鼠标事件必须用同一个手势交接系统拖动")
        gesture.isEnabled = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        gesture.isEnabled = true
        _ = controller.trackExportKey(key(53))
        try check(gesture.state == .possible && gesture.isEnabled && controller.isExporting && controller.store.items.count == 1,
                  "输入已重置时也须保留原生会话，不能把按过 Esc 当成已经取消")
        source.draggingSession(dragSession, endedAt: .zero, operation: [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        try check(gesture.isEnabled && !controller.isExporting && controller.store.items.count == 1,
                  "确认取消后恢复下一轮手势并保留项目")
        print("Staging input smoke passed: AppKit window events, same-gesture handoff and already-reset recognizer during native tracking (offscreen; native completion is a fixture)")
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.failed(message) }
    }

    static func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: code == 49 ? " " : "\u{1b}",
                         charactersIgnoringModifiers: code == 49 ? " " : "\u{1b}", isARepeat: false, keyCode: code)!
    }
}
