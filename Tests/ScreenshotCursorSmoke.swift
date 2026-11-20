// Appended to MacScreenshotCapture.swift to exercise its private selector
// without ordering a window on screen or recording any screen pixels.
// NSCursor.current is application-local; these checks verify cursor/focus
// routing, not the cursor that is physically displayed by the window server.
extension MacScreenshotCapture {
    @MainActor static func smokeDismissRestoresArrow() -> Bool {
        MacScreenshotSelectionCursor.cursor.set()
        let selector = MacScreenshotOverlayPanel(screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), screen: nil)
        precondition(selector.worksWhenModal,
                     "an application picker must not block screenshot selection input")
        let capture = MacScreenshotCapture()
        capture.dismissOverlay()
        return NSCursor.current === NSCursor.arrow
    }
}

extension MacScreenshotSelectionView {
    @MainActor static func smokeWindowClickDispatch() {
        let mainTop: CGFloat = 900
        for frame in [CGRect(x: 0, y: 0, width: 300, height: 220),
                      CGRect(x: 1440, y: -200, width: 300, height: 220)] {
            let target = CGRect(x: frame.minX + 40, y: frame.minY + 25, width: 200, height: 160)
            let candidate = MacScreenshotWindowCandidate(id: 42, hitFrame:
                MacScreenshotGeometry.displayRect(for: target, mainScreenTop: mainTop))
            for flags: NSEvent.ModifierFlags in [[], .shift, .option, [.command, .shift]] {
                for offset in [CGPoint.zero, CGPoint(x: 2, y: -2)] {
                    let panel = MacScreenshotOverlayPanel(screenFrame: frame, screen: nil)
                    panel.isReleasedWhenClosed = false
                    let view = MacScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.size),
                        mainScreenTop: mainTop, candidates: [candidate])
                    panel.contentView = view
                    var callbacks = 0
                    view.onSelect = { selection in
                        callbacks += 1
                        view.lockSelection()
                        guard case .window(let id, let selected) = selection else {
                            preconditionFailure("轻点窗口不能被修饰键变成无效区域")
                        }
                        precondition(id == candidate.id && selected == target,
                            "窗口点击必须使用冻结候选的 ID 和原屏幕位置")
                    }
                    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                            timestamp: 1, windowNumber: panel.windowNumber, context: nil,
                            eventNumber: 1, clickCount: 1, pressure: 0)!
                    }
                    let point = CGPoint(x: 100, y: 80)
                    view.mouseDown(with: event(.leftMouseDown, point))
                    view.mouseUp(with: event(.leftMouseUp,
                        CGPoint(x: point.x + offset.x, y: point.y + offset.y)))
                    precondition(callbacks == 1, "普通轻点、轻微抖动和快捷键尚未松开时均应交接一次窗口选择")
                    view.mouseUp(with: event(.leftMouseUp, point))
                    precondition(callbacks == 1, "已交接选择不能再次触发")
                    panel.contentView = nil
                }
            }
            let panel = MacScreenshotOverlayPanel(screenFrame: frame, screen: nil)
            panel.isReleasedWhenClosed = false
            let view = MacScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.size),
                mainScreenTop: mainTop, candidates: [candidate])
            panel.contentView = view
            var region: CGRect?
            view.onSelect = { if case .region(let rect) = $0 { region = rect } }
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 2, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 2, clickCount: 1, pressure: 0)!
            }
            view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 50, y: 50)))
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 180, y: 140)))
            view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 180, y: 140)))
            precondition(region == CGRect(x: frame.minX + 50, y: frame.minY + 50, width: 130, height: 90),
                "在窗口内实际拖动仍应选择区域，而非误触点选窗口")
            panel.contentView = nil
        }
    }
}

@MainActor
private final class FirstFrameProbeView: NSView {
    var drawCount = 0
    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        NSColor.white.setFill()
        bounds.fill()
    }
}

@MainActor
private final class FocusRecordingPanel: NSPanel {
    var shownForSelection = false
    var hasSelectionFocus = false
    var focusRequests = 0
    var responderRequests = 0
    var cursorResets = 0
    override var isVisible: Bool { shownForSelection }
    override var isKeyWindow: Bool { hasSelectionFocus }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        focusRequests += 1
        hasSelectionFocus = true
    }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        responderRequests += 1
        return true
    }
    override func resetCursorRects() { cursorResets += 1 }
}

extension MacScreenshotLoupeView {
    @MainActor static func smokeGlassHUD() {
        let view = MacScreenshotLoupeView(frame: CGRect(origin: .zero, size: panelSize))
        for text in ["点选窗口 / 拖选区域", "正在准备标注…",
                     ScreenshotStartAction.recognizeText.selectionHints!.selection,
                     ScreenshotStartAction.translate.selectionHints!.selection] {
            view.update(sample: nil, instruction: text)
            view.layoutSubtreeIfNeeded()
            precondition(view.content.superview != nil && view.glass.frame == view.bounds,
                         "操作说明与取色内容必须放在完整的系统玻璃面板内")
            precondition(view.instruction.font!.pointSize == 10 &&
                         view.instruction.textColor == .labelColor &&
                         view.instruction.attributedStringValue.size().width <= view.instruction.frame.width,
                         "操作说明应简短、小号、清晰，并能完整显示")
            precondition(view.hitTest(CGPoint(x: 50, y: 100)) == nil,
                         "玻璃面板不能拦截截图点击或拖动")
        }
        precondition(view.preview.frame.width == view.preview.frame.height &&
                     view.preview.layer!.cornerRadius == 8,
                     "放大区域应为圆角正方形")
        precondition(view.readableFooter.frame.contains(view.colorValue.frame) &&
                     view.readableFooter.frame.contains(view.instruction.frame) &&
                     view.readableFooter.frame.contains(view.keyboardHint.frame),
                     "色值与操作提示必须位于独立可读底衬内")
        let labels = view.content.subviews.compactMap { $0 as? NSTextField }
        precondition(labels.count == 3 && !labels.contains { $0.stringValue.contains("坐标") },
                     "面板只保留色值、操作与按键提示，不再显示坐标")
        precondition(MacScreenshotLoupePreviewView.crosshairColor == .systemBlue,
                     "放大预览的十字线应使用统一蓝色")
    }
}

@main
struct ScreenshotCursorSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        MacScreenshotLoupeView.smokeGlassHUD()
        MacScreenshotSelectionView.smokeWindowClickDispatch()
        defer { NSCursor.arrow.set() }
        let cursor = MacScreenshotSelectionCursor.cursor
        precondition(cursor.image.size == CGSize(width: 36, height: 36)
                     && cursor.hotSpot == CGPoint(x: 18, y: 18),
                     "圆形准星的点击位置必须位于十字交点")
        for action in [ScreenshotStartAction.translate, .recognizeText] {
            let hints = action.selectionHints!
            let view = MacScreenshotSelectionView(frame: CGRect(x: 0, y: 0, width: 300, height: 220),
                                                   mainScreenTop: 900, hints: hints)
            precondition(view.operationHint == hints.selection,
                         "选区时应使用该快捷入口的操作提示")
            view.lockSelection()
            precondition(view.operationHint == hints.preparing,
                         "松手后仍应提示正在准备翻译或识别，而非普通标注")
        }
        let frames = [CGRect(x: 0, y: 0, width: 300, height: 220),
                      CGRect(x: 1440, y: -200, width: 300, height: 220)]
            + NSScreen.screens.map(\.frame)
        for frame in frames {
            let screen = NSScreen.screens.first { $0.frame == frame }
            let panel = MacScreenshotOverlayPanel(screenFrame: frame, screen: screen)
            panel.isReleasedWhenClosed = false
            precondition(panel.animationBehavior == .none,
                         "整屏冻结图不能使用窗口缩放或淡入淡出动画")
            precondition(panel.frame == frame,
                         "截图层必须直接使用屏幕坐标和点尺寸，不得缩放或收进可用区域")
            let firstFrame = FirstFrameProbeView(frame: CGRect(origin: .zero, size: frame.size))
            let childFrame = FirstFrameProbeView(frame: CGRect(x: 20, y: 20, width: 30, height: 30))
            firstFrame.addSubview(childFrame)
            panel.contentView = firstFrame
            panel.prepareForPresentation()
            precondition(firstFrame.drawCount > 0 && childFrame.drawCount > 0 && !panel.isVisible,
                         "冻结图、遮罩及高亮必须在首次显示窗口之前完成绘制")
            if let screen {
                precondition(panel.backingScaleFactor == screen.backingScaleFactor,
                             "冻结层首帧必须采用目标屏幕的像素倍率")
            }
            let view = MacScreenshotSelectionView(frame: CGRect(origin: .zero, size: frame.size),
                                                  mainScreenTop: 900)
            panel.contentView = view
            precondition(!panel.isKeyWindow, "光标状态测试不应显示实际窗口")
            NSCursor.arrow.set()
            view.updateHover(at: CGPoint(x: panel.frame.minX + 20, y: panel.frame.minY + 20))
            precondition(NSCursor.current === cursor,
                         "选择层首次出现时应设置应用内十字光标状态")
            view.updateTrackingAreas()
            precondition(view.trackingAreas.contains {
                $0.options.contains(.activeAlways) && $0.options.contains(.mouseEnteredAndExited)
                    && !$0.options.contains(.cursorUpdate)
            }, "必须支持非活跃状态跟踪，且不能组合系统不支持的 activeAlways 与 cursorUpdate")
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 20, y: 20),
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            NSCursor.arrow.set()
            view.mouseEntered(with: event)
            precondition(NSCursor.current === cursor, "进入选择层应恢复圆形准星")
            NSCursor.arrow.set()
            view.mouseMoved(with: event)
            precondition(NSCursor.current === cursor, "移动时应保持圆形准星")
            view.mouseDown(with: event)
            NSCursor.arrow.set()
            view.mouseDragged(with: event)
            precondition(NSCursor.current === cursor, "拖选区域时应保持圆形准星")
            view.lockSelection()
            NSCursor.arrow.set()
            view.cursorUpdate(with: event)
            view.mouseMoved(with: event)
            precondition(NSCursor.current === NSCursor.arrow,
                         "已交接的选择层不能覆盖标注工具或缩放锚点的光标")
            panel.contentView = nil

            let focusPanel = FocusRecordingPanel(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            focusPanel.isReleasedWhenClosed = false
            let focusView = MacScreenshotSelectionView(
                frame: CGRect(origin: .zero, size: frame.size), mainScreenTop: 900)
            focusPanel.contentView = focusView
            let pointer = CGPoint(x: frame.minX + 20, y: frame.minY + 20)
            focusView.updateHover(at: pointer)
            precondition(focusPanel.focusRequests == 0, "不能恢复已隐藏的选择层")
            focusPanel.shownForSelection = true
            focusView.updateHover(at: pointer)
            precondition(focusPanel.focusRequests == 1 && focusPanel.responderRequests == 1
                         && focusPanel.cursorResets == 1,
                         "可见的非激活选择层应取得键盘焦点并刷新系统光标区域")
            focusView.updateHover(at: pointer)
            precondition(focusPanel.focusRequests == 1, "已有焦点时不应重复抢焦点")
            focusPanel.hasSelectionFocus = false
            focusView.updateHover(at: pointer)
            precondition(focusPanel.focusRequests == 2, "重新进入或切屏后应恢复选择层焦点")
            focusView.lockSelection()
            focusPanel.hasSelectionFocus = false
            focusView.updateHover(at: pointer)
            precondition(focusPanel.focusRequests == 2, "已交接的选择层不能抢回键盘焦点")
            focusPanel.contentView = nil
        }
        precondition(MacScreenshotCapture.smokeDismissRestoresArrow(), "取消或失败应恢复箭头")
        print("Screenshot cursor routing smoke passed: no entry animation, hidden first-frame paint, reticle hotspot, key focus, display changes, tracking, drag, handoff and cleanup (no desktop display check)")
    }
}
