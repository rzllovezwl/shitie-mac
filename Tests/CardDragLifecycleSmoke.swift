import AppKit
import ObjectiveC
import ImageIO

// Compile with the production AppKit card views extracted by VerifyTestBuild.
enum ClipboardCardOrderScope: Hashable {
    case history, favorite(UUID), pins, group(UUID)
}
struct ClipboardDragPayload {
    let writers: [NSPasteboardWriting]
    let sourceEntryIDs: [UUID]
    var reorderScope: ClipboardCardOrderScope? = nil
    let exportsContent: Bool
}
struct CardContextAction {
    let title: String
    let shortcut: String?
    let isEnabled: Bool
    let perform: () -> Void
    let children: [CardContextAction] = []
}

private final class InitialDragSession: NSDraggingSession {
    private var animatesBack = true
    override var draggingLocation: NSPoint { .zero }
    override var animatesToStartingPositionsOnCancelOrFail: Bool {
        get { animatesBack }
        set { animatesBack = newValue }
    }
}

private final class TestCardInteractionView: CardInteractionView {
    var testSession: InitialDragSession!
    private(set) var nativeStarts = 0
    private(set) var keyboardPreparations = 0
    private(set) var nativeStartEvents: [NSEvent] = []
    private(set) var gestureStarts = 0
    private(set) var receivedGesture: NSGestureRecognizer?
    private(set) var nativeFrames: [NSRect] = []

    override func prepareNativeDragKeyboardFocus() { keyboardPreparations += 1 }

    override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent,
                                       source: any NSDraggingSource) -> NSDraggingSession {
        nativeStarts += 1
        nativeStartEvents.append(event)
        nativeFrames = items.map(\.draggingFrame)
        draggingSession(testSession, willBeginAt: .zero)
        return testSession
    }
    @available(macOS 27.0, *)
    override func beginDraggingSession(items: [NSDraggingItem], gesture: NSGestureRecognizer,
                                       source: any NSDraggingSource) -> NSDraggingSession? {
        nativeStarts += 1
        gestureStarts += 1
        receivedGesture = gesture
        nativeFrames = items.map(\.draggingFrame)
        draggingSession(testSession, willBeginAt: .zero)
        return testSession
    }
}

@main
struct CardDragLifecycleSmoke {
    enum Failure: Error { case failed(String) }
    // The callback fixture has no CoreDrag handle; keep it for the test
    // process lifetime instead of asking CoreDrag to dispose a real session.
    @MainActor private static let initialSession = InitialDragSession()
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        try checkGestureInput()
        try checkShelfGesturePreview()
        try checkShelfDrag()
        try checkCardReordering()
        try checkReorderAutoscroll()
        let view = CardInteractionView(frame: CGRect(x: 0, y: 0, width: 200, height: 250))
        let session = initialSession
        var moves: [CGPoint] = []
        var endings: [Bool] = []
        view.onDragMoved = { moves.append($0) }
        view.onEndDrag = { endings.append($0) }
        view.draggingSession(session, willBeginAt: CGPoint(x: 640, y: 160))
        try check(moves.isEmpty, "开始拖动不应发送零值或未初始化的位置，导致面板立即收起")
        try check(!session.animatesToStartingPositionsOnCancelOrFail, "取消时不应把缩略图飞回旧位置")
        for point in [CGPoint(x: 640, y: 200), CGPoint(x: -1000, y: 600),
                      CGPoint(x: 800, y: -400)] {
            view.draggingSession(session, movedTo: point)
            try check(moves.last == point, "必须使用移动回调提供的屏幕坐标，而非会话的旧位置")
        }
        view.draggingSession(session, endedAt: .zero, operation: [])
        view.draggingSession(session, endedAt: .zero, operation: .copy)
        try check(endings == [false, true], "取消与成功投放的结束状态不正确")
        print("Card drag lifecycle smoke passed: persistent backdrop, reordering, favorite priority, cancellation and native handoff")
    }

    @MainActor
    private static func checkGestureInput() throws {
        for selector in [#selector(NSResponder.mouseDown(with:)), #selector(NSResponder.mouseDragged(with:)),
                         #selector(NSResponder.mouseUp(with:))] {
            let implementation = class_getMethodImplementation(CardInteractionView.self, selector)!
            let inherited = class_getMethodImplementation(NSView.self, selector)!
            try check(unsafeBitCast(implementation, to: UnsafeRawPointer.self) ==
                      unsafeBitCast(inherited, to: UnsafeRawPointer.self),
                      "拖动源不能同时保留视图鼠标重载与手势入口，导致兼容跟踪路径竞争")
        }
        let window = NSPanel(contentRect: NSRect(x: -100000, y: -100000, width: 200, height: 160),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        let view = TestCardInteractionView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.testSession = initialSession
        var selected = 0
        var pasted = 0
        var results: [Bool] = []
        view.onSelect = { _ in selected += 1 }
        view.onPaste = { pasted += 1 }
        view.onEndDrag = { results.append($0) }
        view.onBeginDrag = { ClipboardDragPayload(writers: [NSPasteboardItem()], sourceEntryIDs: [UUID()], exportsContent: true) }
        let gesture = view.gestureRecognizers.compactMap { $0 as? ContentDragGestureRecognizer }.first!
        try check(gesture.allowedTouchTypes.isEmpty, "鼠标拖动识别器不应混入触摸输入")
        func event(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        func deliver(_ event: NSEvent) {
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let down = event(.leftMouseDown, NSPoint(x: 24, y: 24))
        try check(view.gestureRecognizer(gesture, shouldAttemptToRecognizeWith: down), "命中的卡片须接收手势")
        deliver(down)
        deliver(event(.leftMouseUp, NSPoint(x: 24, y: 24)))
        gesture.reset()
        deliver(event(.leftMouseDown, NSPoint(x: 24, y: 24), clicks: 2))
        deliver(event(.leftMouseUp, NSPoint(x: 24, y: 24), clicks: 2))
        gesture.reset()
        try check(selected == 1 && pasted == 1 && view.nativeStarts == 0,
                  "统一手势入口必须保留普通选择和双击粘贴，点击不能发起拖动（selected=\(selected), pasted=\(pasted), starts=\(view.nativeStarts)）")
        deliver(down)
        deliver(event(.leftMouseDragged, NSPoint(x: 40, y: 24)))
        if #available(macOS 27.0, *) {
            try check(view.gestureStarts == 1 && view.receivedGesture === gesture && view.keyboardPreparations == 0,
                      "卡片须将同一个活动手势交给系统，而不是重新进入鼠标兼容路径")
            try check(view.nativeFrames.first.map { NSPoint(x: $0.midX, y: $0.midY) } == NSPoint(x: 40, y: 24),
                      "手势交接时缩略图须位于当前指针，而不是最初的按下位置")
        } else {
            try check(view.nativeStartEvents.last === down, "旧系统应沿用原始按下事件")
        }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        // Real 315 diagnostics show AppKit has already reset this recognizer
        // when willBegin arrives. A live-gesture fixture hid that distinction.
        gesture.isEnabled = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        gesture.isEnabled = true
        try check(gesture.state == .possible, "模拟系统交接后输入手势应已重置")
        try check(view.trackNativeDragKey(escape) === escape && gesture.isEnabled && results.isEmpty,
                  "手势已重置时 Esc 仍须透传，不能把输入状态当成原生会话取消结果")
        view.draggingSession(initialSession, endedAt: .zero, operation: [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        try check(results == [false] && gesture.isEnabled, "确认取消后应恢复下一次输入")
        gesture.reset()
        deliver(down)
        deliver(event(.leftMouseDragged, NSPoint(x: 40, y: 24)))
        _ = view.trackNativeDragKey(escape)
        view.draggingSession(initialSession, endedAt: .zero, operation: .copy)
        try check(results == [false, true], "已收到取消请求但系统确认投放成功时，必须按实际结果结束")
        print("Content drag input smoke passed: AppKit window input, click/double click, pointer-aligned preview, reset-before-Escape handoff and authoritative completion (offscreen; native completion is a fixture)")
    }

    @MainActor
    private static func checkShelfGesturePreview() throws {
        guard #available(macOS 27.0, *) else { return }
        let window = ShelfPanel(contentRect: NSRect(x: -100000, y: -100000, width: 600, height: 300),
                                styleMask: [.borderless], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let view = TestCardInteractionView(frame: NSRect(x: 10, y: 20, width: 120, height: 200))
        window.contentView = content
        content.addSubview(view)
        view.testSession = initialSession
        view.onBeginDrag = {
            ClipboardDragPayload(writers: [NSPasteboardItem(), NSPasteboardItem()],
                                 sourceEntryIDs: [UUID(), UUID()], exportsContent: true)
        }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for (index, step) in [(NSEvent.EventType.leftMouseDown, NSPoint(x: 70, y: 70)),
                              (.leftMouseDragged, NSPoint(x: 320, y: 150)),
                              (.leftMouseDragged, NSPoint(x: 605, y: 260))].enumerated() {
            window.sendEvent(NSEvent.mouseEvent(with: step.0, location: step.1, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: index, clickCount: 1, pressure: 1)!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try check(view.gestureStarts == 1 && view.nativeFrames.count == 2,
                  "面板内长距离移动后，出界时应只交接一次原生多项拖动")
        let current = view.convert(NSPoint(x: 605, y: 260), from: nil)
        for (index, frame) in view.nativeFrames.enumerated() {
            let offset = CGFloat(index) * 4
            try check(NSPoint(x: frame.midX, y: frame.midY) ==
                      NSPoint(x: current.x + offset, y: current.y - offset),
                      "缩略图须紧随出界时指针，不能留下初次按下点到出界点的距离")
        }
        view.draggingSession(initialSession, endedAt: .zero, operation: [])
    }

    @MainActor
    private static func checkReorderAutoscroll() throws {
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        panel.contentView = content
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 250))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 250))
        scroll.documentView = document
        content.addSubview(scroll)
        content.addSubview(CardReorderViewportView(frame: scroll.frame))
        for index in 0..<10 {
            let target = CardReorderDropView(frame: NSRect(x: index * 140 + 5, y: 10, width: 130, height: 230))
            document.addSubview(target)
        }
        panel.showLocalCardDrag(NSImage(size: NSSize(width: 40, height: 40)),
                                at: NSPoint(x: 590, y: 100), ids: [UUID()], scope: .history)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try check(scroll.contentView.bounds.minX > 0, "靠近滚动区边缘应能继续拖到屏外卡片")
        panel.clearLocalCardDragPreview()
        let stopped = scroll.contentView.bounds.origin
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        try check(scroll.contentView.bounds.origin == stopped, "结束或取消拖动后应停止自动滚动")
    }

    @MainActor
    private static func checkCardReordering() throws {
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        panel.contentView = content
        let viewport = CardReorderViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 250))
        content.addSubview(viewport)
        let source = UUID(), targetID = UUID()
        let card = TestCardInteractionView(frame: NSRect(x: 10, y: 20, width: 120, height: 200))
        card.testSession = initialSession
        card.onBeginDrag = {
            ClipboardDragPayload(writers: [NSPasteboardItem()], sourceEntryIDs: [source],
                                 reorderScope: .history, exportsContent: true)
        }
        content.addSubview(card)
        let target = CardReorderDropView(frame: NSRect(x: 150, y: 20, width: 120, height: 200))
        target.entryID = targetID
        target.scope = .history
        var placements: [Bool] = []
        target.onDrop = { ids, after in
            guard ids == [source] else { return false }
            placements.append(after)
            return true
        }
        content.addSubview(target)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = NSPoint(x: 50, y: 100), before = NSPoint(x: 160, y: 100), after = NSPoint(x: 265, y: 100)
        try check(panel.cardReorderTarget(at: before, ids: [source], scope: .history)?.after == false,
                  "卡片左半侧应插入到前面")
        try check(panel.cardReorderTarget(at: after, ids: [source], scope: .history)?.after == true,
                  "卡片右半侧应插入到后面")
        try check(panel.cardReorderTarget(at: before, ids: [targetID], scope: .history) == nil &&
                  panel.cardReorderTarget(at: before, ids: [source], scope: .pins) == nil &&
                  panel.cardReorderTarget(at: NSPoint(x: 200, y: 285), ids: [source], scope: .history) == nil,
                  "拖动自己、跨钉住区或卡片区域外不应排序")
        card.pointerDown(with: mouse(.leftMouseDown, start))
        card.pointerDragged(with: mouse(.leftMouseDragged, after))
        try check(placements.isEmpty && card.nativeStarts == 0, "移动时不应写入排序或启动系统拖动")
        try check(card.cancelLocalCardDrag(), "Esc 取消应清除排序会话")
        try check(placements.isEmpty, "取消不应提交排序")
        card.pointerDown(with: mouse(.leftMouseDown, start))
        card.pointerDragged(with: mouse(.leftMouseDragged, after))
        card.pointerUp(with: mouse(.leftMouseUp, after))
        try check(placements == [true] && panel.localCardDragSource == nil, "松手应只提交一次插入位置")
        target.isVertical = true
        try check(panel.cardReorderTarget(at: NSPoint(x: 200, y: 30), ids: [source], scope: .history)?.after == true &&
                  panel.cardReorderTarget(at: NSPoint(x: 200, y: 210), ids: [source], scope: .history)?.after == false,
                  "竖向面板应使用上下插入方向")
        let favorite = FavoriteDropView(frame: target.frame)
        favorite.onDrop = { _ in placements.append(false); return true }
        content.addSubview(favorite)
        panel.localCardDropAction(at: before, ids: [source], scope: .history)?()
        try check(placements == [true, false], "收藏落点应优先于卡片排序")
    }

    @MainActor
    private static func checkShelfDrag() throws {
        let panel = ShelfPanel(contentRect: NSRect(x: 20, y: 30, width: 500, height: 300),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: true)
        let surface = ShelfPanelSurface(frame: .zero)
        panel.contentView = surface
        let container = NSView()
        surface.setShelfContent(container)
        guard let backdrop = surface.subviews.first else { throw Failure.failed("面板应有独立的系统底板") }
        func checkBackdrop() throws {
            try check(panel.contentView === surface && surface.subviews.first === backdrop &&
                      backdrop.frame == surface.bounds && backdrop.alphaValue == 1,
                      "拖动、收藏与内容更新都应保留同一块底板")
            try check(surface.clipsToBounds && surface.layer?.masksToBounds == true &&
                      surface.layer?.cornerRadius == ShelfPanelSurface.cornerRadius &&
                      surface.layer?.cornerCurve == .continuous,
                      "拖动、内容更新和尺寸变化后，最外层仍应统一裁切底板与内容，避免圆角外残留矩形")
            if #available(macOS 26.0, *) {
                guard let glass = backdrop as? NSGlassEffectView else { throw Failure.failed("新系统应使用原生液态玻璃") }
                try check(glass.style == .regular && glass.tintColor == nil &&
                          glass.cornerRadius == ShelfPanelSurface.cornerRadius,
                          "底板应保持常规玻璃的原生颜色和圆角")
                if #available(macOS 27.0, *) {
                    try check(!glass.effectIsInteractive, "底板不应对拖动产生交互变色")
                }
            } else {
                guard let effect = backdrop as? NSVisualEffectView else { throw Failure.failed("旧系统应使用原生磨砂") }
                try check(effect.state == .active && effect.blendingMode == .behindWindow && effect.maskImage != nil,
                          "旧系统的圆角磨砂底板应持续生效")
            }
        }
        try checkBackdrop()
        let card = TestCardInteractionView(frame: NSRect(x: 40, y: 40, width: 100, height: 150))
        card.testSession = initialSession
        card.deferSelectionUntilMouseUp = true
        let favorite = FavoriteDropView(frame: NSRect(x: 250, y: 250, width: 100, height: 30))
        container.addSubview(card)
        container.addSubview(favorite)
        let selectedIDs = [UUID(), UUID()]
        var exportsContent = true
        var clicks = 0
        var tabOpens = 0
        var targets: [Bool] = []
        var drops: [[UUID]] = []
        var nativeLocations: [NSPoint] = []
        var nativeResults: [Bool] = []
        card.onSelect = { _ in clicks += 1 }
        card.onDragMoved = { nativeLocations.append($0) }
        card.onEndDrag = { nativeResults.append($0) }
        card.onBeginDrag = {
            ClipboardDragPayload(writers: [NSPasteboardItem()], sourceEntryIDs: selectedIDs,
                                 exportsContent: exportsContent)
        }
        favorite.onOpen = { tabOpens += 1 }
        favorite.onTargeted = { targets.append($0) }
        favorite.onDrop = { drops.append($0); return true }

        let cardPoint = NSPoint(x: 70, y: 70)
        let favoritePoint = NSPoint(x: 300, y: 265)
        let blankPoint = NSPoint(x: 450, y: 145)
        let outsidePoint = NSPoint(x: 501, y: 145)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerUp(with: mouse(.leftMouseUp, at: cardPoint))
        try check(clicks == 1, "点击卡片仍应选中")

        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: favoritePoint))
        try check(panel.localCardDragSource === card && surface.subviews.count == 3,
                  "面板内应显示本地拖动缩略图")
        try checkBackdrop()
        try check(surface.hitTest(favoritePoint) === favorite, "拖动缩略图不应遮挡收藏落点")
        try check(targets == [true] && card.nativeStarts == 0, "悬停收藏应高亮且不启动系统拖动")
        card.pointerUp(with: mouse(.leftMouseUp, at: favoritePoint))
        try check(drops == [selectedIDs] && tabOpens == 0, "拖入收藏应一次写入所有选中项并保持标签")
        try check(panel.localCardDragSource == nil && surface.subviews.count == 2 && targets == [true, false],
                  "松手应清除缩略图和收藏高亮")
        try checkBackdrop()

        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: blankPoint))
        card.pointerUp(with: mouse(.leftMouseUp, at: blankPoint))
        try check(drops.count == 1 && card.nativeStarts == 0, "面板内空白处松手应结束拖动")

        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: favoritePoint))
        try check(card.cancelLocalCardDrag(), "Esc 应能取消面板内拖动")
        card.pointerUp(with: mouse(.leftMouseUp, at: favoritePoint))
        try check(drops.count == 1 && surface.subviews.count == 2 && targets.last == false,
                  "取消后松手不应收藏或留下拖动反馈")
        try checkBackdrop()

        exportsContent = false
        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: outsidePoint))
        try check(card.nativeStarts == 0, "原内容不可用时不应启动系统拖放")
        card.pointerDragged(with: mouse(.leftMouseDragged, at: favoritePoint))
        card.pointerUp(with: mouse(.leftMouseUp, at: favoritePoint))
        try check(drops == [selectedIDs, selectedIDs], "原内容不可用时仍应能收藏历史项")

        exportsContent = true
        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: favoritePoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: outsidePoint))
        try check(card.nativeStarts == 1 && nativeLocations == [panel.convertPoint(toScreen: outsidePoint)],
                  "出界时应启动系统拖放并上报实际出界位置")
        try check(panel.localCardDragSource == nil && surface.subviews.count == 2 && targets.last == false,
                  "系统接管前应结束面板内拖动反馈")
        try check(panel.nativeCardDragSource === card, "系统拖动期间面板必须保留拖动源")
        try check(card.keyboardPreparations == 1 && card.nativeStartEvents[0].type == .leftMouseDown &&
                  card.nativeStartEvents[0].locationInWindow == cardPoint,
                  "拖出面板必须先接管键盘焦点，并用原始按下事件启动系统拖动")
        let escape = NSEvent.keyEvent(with: .keyDown, location: outsidePoint, modifierFlags: [],
                                      timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        try check(card.trackNativeDragKey(escape) === escape,
                  "面板外的 Escape 必须交给 AppKit 结束原生拖动，不能吞掉")
        try check(card.draggingSession(initialSession, sourceOperationMaskFor: .outsideApplication) == .copy &&
                  card.draggingSession(initialSession, sourceOperationMaskFor: .withinApplication) == .copy,
                  "取消请求不能伪造系统已结束；最终由原生回调确认是否投放")
        card.draggingSession(initialSession, movedTo: panel.convertPoint(toScreen: blankPoint))
        try check(nativeLocations.count == 1, "取消后不应继续移动面板")
        card.draggingSession(initialSession, endedAt: .zero, operation: [])
        try check(nativeResults == [false] && panel.nativeCardDragSource == nil,
                  "系统确认取消后应恢复面板并释放拖动源")
        card.pointerUp(with: mouse(.leftMouseUp, at: favoritePoint))
        try check(drops.count == 2, "取消系统拖动后松手不能触发收藏")
        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: outsidePoint))
        try check(card.draggingSession(initialSession, sourceOperationMaskFor: .outsideApplication) == .copy,
                  "上一轮取消不能影响下一轮拖动")
        card.draggingSession(initialSession, endedAt: .zero, operation: .copy)
        try check(nativeResults == [false, true], "后续正常投放应正常结束")
        try checkBackdrop()

        // A horizontally clipped tag can still have a live AppKit view.
        // It must never accept a drop over History, the add button, or any other header action.
        let custom = FavoriteDropView(frame: NSRect(x: 354, y: 250, width: 100, height: 30))
        let viewport = FavoriteDropViewportView(frame: NSRect(x: 250, y: 250, width: 145, height: 30))
        container.addSubview(viewport, positioned: .below, relativeTo: favorite)
        container.addSubview(custom)
        var customTargets: [Bool] = []
        var customDrops: [[UUID]] = []
        custom.onOpen = {}
        custom.onTargeted = { customTargets.append($0) }
        custom.onDrop = { customDrops.append($0); return true }
        let visibleCustomPoint = NSPoint(x: 377, y: 265)
        let clippedCustomPoint = NSPoint(x: 427, y: 265)
        try check(panel.favoriteDropTarget(at: visibleCustomPoint) === custom &&
                  panel.favoriteDropTarget(at: clippedCustomPoint) == nil &&
                  surface.hitTest(clippedCustomPoint) !== custom,
                  "只有可见标签区域能响应点击和收藏拖放")
        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: favoritePoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: visibleCustomPoint))
        try check(targets.last == false && customTargets == [true], "切换落点时应只高亮新分类")
        card.pointerUp(with: mouse(.leftMouseUp, at: visibleCustomPoint))
        try check(customDrops == [selectedIDs] && drops.count == 2 && customTargets == [true, false],
                  "松手只能收藏到指针所在的分类")
        try checkBackdrop()

        let add = FavoriteDropView(frame: NSRect(x: 420, y: 250, width: 26, height: 30))
        add.clipsToFavoriteViewport = false
        container.addSubview(add)
        let addPoint = NSPoint(x: 433, y: 265)
        var addTargets: [Bool] = []
        var pendingCategories: [[UUID]] = []
        add.onTargeted = { addTargets.append($0) }
        add.onDrop = { pendingCategories.append($0); return true }
        try check(panel.favoriteDropTarget(at: addPoint) === add && surface.hitTest(addPoint) !== add,
                  "加号应接收拖放，同时将点按交给原按钮")
        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: visibleCustomPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: addPoint))
        try check(addTargets == [true] && customTargets.last == false && pendingCategories.isEmpty,
                  "悬停加号应显示反馈，松手前不打开表单")
        card.pointerUp(with: mouse(.leftMouseUp, at: addPoint))
        try check(pendingCategories == [selectedIDs] && addTargets == [true, false],
                  "拖到加号松手应把所有卡片交给新分类表单")
        card.pointerDown(with: mouse(.leftMouseDown, at: cardPoint))
        card.pointerDragged(with: mouse(.leftMouseDragged, at: addPoint))
        try check(card.cancelLocalCardDrag(), "应能取消拖到加号的操作")
        card.pointerUp(with: mouse(.leftMouseUp, at: addPoint))
        try check(pendingCategories.count == 1 && addTargets.last == false,
                  "取消后应收起提示并丢弃尚未投放的卡片")
        try checkBackdrop()

        let newContent = NSView()
        surface.setShelfContent(newContent)
        panel.setContentSize(NSSize(width: 720, height: 360))
        try checkBackdrop()
        try check(container.superview == nil && newContent.frame == surface.bounds,
                  "重新打开面板时应仅替换内容，并让底板和内容跟随窗口尺寸")
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.failed(message) }
    }
}
