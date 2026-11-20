// Appended to the production canvas. Uses synthetic images, named pasteboards
// and offscreen windows; does not read or change the user's clipboard.
extension ScreenshotAnnotationCanvas {
    fileprivate func elementFixture(_ items: [ScreenshotAnnotation], selected: Int? = 0) {
        annotations = items
        selectedIndex = selected
        hoveredIndex = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }
    fileprivate var selectedElementForSmoke: Int? { selectedIndex }
    fileprivate func elementLocation(_ point: CGPoint) -> CGPoint { viewPoint(point) }
    fileprivate func startElementTextInput() {
        beginText(at: CGPoint(x: 50, y: 200), viewPoint: viewPoint(CGPoint(x: 50, y: 200)),
                  editing: nil, translationLine: nil)
    }
}

@main
struct ScreenshotElementClipboardSmoke {
    enum Failure: Error { case failed(String) }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        let board = NSPasteboard(name: .init("ClipHoookElementSmoke-" + UUID().uuidString))
        defer { board.clearContents(); board.releaseGlobally() }
        try copyAndPaste(board)
        try stylesAndCrossImage(board)
        try discardPreferences()
        try toolDefaultStyles()
        try discardMark()
        try discardOpacity()
        try optionDrag()
        try inputIsolation(board)
        print("Annotation element clipboard smoke passed: editable copy/paste, per-tool defaults, discard opacity and movement, cross-image OCR, undo/redo, Option drag, resize, cancellation and input isolation")
    }

    @MainActor private static func canvas(height: Int = 420) -> (ScreenshotAnnotationCanvas, NSPanel) {
        let context = CGContext(data: nil, width: 600, height: height, bitsPerComponent: 8,
            bytesPerRow: 2400, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: height))
        let view = ScreenshotAnnotationCanvas(image: context.makeImage()!)
        let panel = NSPanel(contentRect: CGRect(x: -100000, y: -100000, width: 640, height: height + 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 640, height: height + 40)
        return (view, panel)
    }

    @MainActor private static func key(_ code: UInt16, in panel: NSPanel) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1, windowNumber: panel.windowNumber, context: nil,
            characters: code == 8 ? "c" : "v", charactersIgnoringModifiers: code == 8 ? "c" : "v",
            isARepeat: false, keyCode: code)!
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType, _ point: CGPoint,
        _ view: ScreenshotAnnotationCanvas, _ panel: NSPanel, option: Bool = true) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(view.elementLocation(point), to: nil),
            modifierFlags: option ? .option : [], timestamp: 1, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.failed(message) }
    }

    @MainActor private static func copyAndPaste(_ board: NSPasteboard) throws {
        let (view, panel) = canvas()
        defer { panel.contentView = nil }
        let original = ScreenshotAnnotation.styledRectangleWithRadius(
            CGRect(x: 100, y: 120, width: 100, height: 60), style: .roundedOutline, width: 5, radius: 8).colored(.blue)
        view.elementFixture([original])
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(original)
        try check(view.handleElementClipboardShortcut(key(8, in: panel), pasteboard: board), "⌘C must copy the selected element")
        try check(!view.canUndo && view.annotations.count == 1, "copy must not mutate the image or add an undo step")
        let archived = try JSONDecoder().decode(ScreenshotAnnotationDocument.self,
            from: board.data(forType: ScreenshotAnnotationCanvas.elementPasteboardType)!)
        try check(try encoder.encode(archived.annotations[0]) == bytes, "clipboard must retain the editable original and its style")
        try check(view.handleElementClipboardShortcut(key(9, in: panel), pasteboard: board), "⌘V must paste an editable element")
        try check(view.annotations.count == 2 && view.selectedElementForSmoke == 1, "paste must select its new copy")
        guard case .styledRectangleWithRadius(let rect, let style, let width, let radius) = view.annotations[1].shape else {
            throw Failure.failed("pasted rectangle flattened or lost its type")
        }
        try check(rect == CGRect(x: 112, y: 108, width: 100, height: 60)
            && style == .roundedOutline && width == 5 && radius == 8 && view.annotations[1].color == .blue,
            "paste must offset the copy and preserve color, corners and stroke")
        try check(try encoder.encode(view.annotations[0]) == bytes, "original must remain untouched")
        view.undo()
        try check(view.annotations.count == 1, "one undo must remove a paste")
        view.redo()
        try check(view.annotations.count == 2, "redo must restore a paste")
        try check(view.pasteElement(from: board), "repeated paste must work")
        guard case .styledRectangleWithRadius(let next, _, _, _) = view.annotations[2].shape else { throw Failure.failed("missing second paste") }
        try check(next.origin == CGPoint(x: 124, y: 96), "repeated paste must visibly stagger copies")
        let payload = try view.editPayload(maximumBytes: 2_000_000)!
        let (reopened, host) = canvas()
        defer { host.contentView = nil }
        try check(reopened.loadDocument(payload.annotationData) && reopened.annotations.count == 3,
                  "saved/reopened edits must retain copied elements")
        reopened.elementFixture(reopened.annotations, selected: 2)
        reopened.nudgeSelectedElement(dx: 7, dy: 0)
        guard case .styledRectangleWithRadius(let moved, _, _, _) = reopened.annotations[2].shape else { throw Failure.failed("copy is not editable") }
        try check(moved.minX == 131, "pasted element must remain editable after reopen")
    }

    @MainActor private static func stylesAndCrossImage(_ board: NSPasteboard) throws {
        let (source, sourcePanel) = canvas()
        let (target, targetPanel) = canvas(height: 700)
        defer { sourcePanel.contentView = nil; targetPanel.contentView = nil }
        let marks: [ScreenshotAnnotation] = [
            .styledRectangleWithRadius(CGRect(x: 40, y: 80, width: 120, height: 70),
                style: .discard, width: 6, radius: 9).colored(.blue),
            .sizedBezierArrow(start: CGPoint(x: 50, y: 100), control: CGPoint(x: 110, y: 170),
                end: CGPoint(x: 180, y: 100), width: 4, scale: 2).colored(.green),
            .styledText(CGPoint(x: 60, y: 220), "示例🙂\nText", fontSize: 20, style: .outlinedShadow).colored(.blue),
            .pen([.init(point: CGPoint(x: 90, y: 90), incoming: nil, outgoing: CGPoint(x: 130, y: 160)),
                  .init(point: CGPoint(x: 190, y: 120), incoming: CGPoint(x: 150, y: 180), outgoing: nil)], width: 6, closed: false),
            .rectangularMagnifier(CGRect(x: 70, y: 80, width: 80, height: 60), magnification: 3.5),
            .highlighter([CGPoint(x: 50, y: 200), CGPoint(x: 150, y: 220)], 22, opacity: 35),
            .number(CGPoint(x: 90, y: 200), 7, 16),
            .obscure(CGRect(x: 40, y: 80, width: 100, height: 70), mode: .blur, strength: 3)
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for item in marks {
            source.elementFixture([item]); target.elementFixture([])
            try check(source.copySelectedElement(to: board) && target.pasteElement(from: board), "all editable styles must copy between canvases")
            let archived = try JSONDecoder().decode(ScreenshotAnnotationDocument.self,
                from: board.data(forType: ScreenshotAnnotationCanvas.elementPasteboardType)!)
            try check(try encoder.encode(item) == encoder.encode(archived.annotations[0]), "clipboard serialization must preserve each element's metadata")
        }
        source.elementFixture([.translation([.init(sourceRect: CGRect(x: 40, y: 60, width: 120, height: 20), text: "译文", fontSize: 17)])])
        target.elementFixture([])
        try check(source.copySelectedElement(to: board) && target.pasteElement(from: board), "OCR overlay must be pasteable")
        guard case .translation(let lines) = target.annotations[0].shape else { throw Failure.failed("OCR overlay type lost") }
        try check(lines[0].sourceRect == CGRect(x: 52, y: 352, width: 120, height: 20)
            && lines[0].text == "译文" && lines[0].fontSize == 17,
            "cross-image paste must convert top-origin OCR bounds using the destination height")
        // A real embedded PNG must travel with its editable sticker.
        let pixel = NSBitmapImageRep(cgImage: source.imageForElementSmoke())
        let asset = ScreenshotStickerAsset.decode(pixel.representation(using: .png, properties: [:])!)!
        source.elementFixture([.sticker(CGRect(x: 50, y: 100, width: 150, height: 105), asset)])
        target.elementFixture([])
        try check(source.copySelectedElement(to: board) && target.pasteElement(from: board), "embedded sticker must copy")
        guard case .sticker(let rect, let pasted) = target.annotations[0].shape else { throw Failure.failed("sticker lost") }
        try check(rect.origin == CGPoint(x: 62, y: 88) && pasted.pngData == asset.pngData && pasted.id == asset.id,
            "sticker pixels and identity must survive without external file access")
    }

    private static func discardPreferences() throws {
        let suite = "ClipHoookDiscardSmoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScreenshotAnnotationPreferences.self
        defaults.set(preferences.rememberLastTool, forKey: preferences.startupToolKey)
        defaults.set(ScreenshotAnnotationTool.rectangle.rawValue, forKey: preferences.lastToolKey)
        defaults.set(4, forKey: preferences.rectangleStyleKey)
        defaults.set(5.0, forKey: preferences.rectangleWidthKey)
        preferences.migrateDiscardStyle(in: defaults)
        try check(ScreenshotRectangleStyle(rawValue: 4) == .discard
            && preferences.startupTool(in: defaults) == .discard
            && defaults.integer(forKey: preferences.rectangleStyleKey) == ScreenshotRectangleStyle.roundedOutline.rawValue
            && defaults.double(forKey: preferences.discardWidthKey) == 5,
            "旧划除样式应迁移为独立工具，保留线宽和旧标注格式")
        defaults.set(ScreenshotAnnotationTool.rectangle.rawValue, forKey: preferences.lastToolKey)
        preferences.migrateDiscardStyle(in: defaults)
        try check(preferences.startupTool(in: defaults) == .rectangle, "迁移不能反复覆盖用户之后选择的工具")
    }

    @MainActor private static func toolDefaultStyles() throws {
        let name = "ClipHoookToolDefaultsSmoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ScreenshotAnnotationPreferences.self
        defaults.set(false, forKey: preferences.remembersToolAndStyleKey)
        defaults.set(12, forKey: preferences.rectangleWidthKey)
        let presets: [(ScreenshotAnnotationTool, ScreenshotAnnotationColor, Double)] = [
            (.rectangle, .gold, 7), (.ellipse, .blue, 3), (.arrow, .green, 4),
            (.highlighter, .teal, 11), (.text, .violet, 2.5), (.number, .orange, 3),
            (.pen, .graphite, 6), (.brush, .blue, 9)
        ]
        for (tool, color, width) in presets {
            defaults.set(color.rawValue, forKey: preferences.colorKey(for: tool))
            defaults.set(width, forKey: preferences.defaultWidthKey(for: tool))
        }
        let (view, panel) = canvas()
        defer { panel.contentView = nil }
        view.strokePixelsPerPoint = 1
        view.loadToolDefaults(from: defaults)
        for (tool, color, _) in presets {
            view.tool = tool
            try check(view.annotationColor == color, "切换工具应载入各自的默认颜色")
        }
        try check(view.rectangleLineWidthPoints == 7 && view.ellipseLineWidthPoints == 3 &&
                  view.penLineWidthPoints == 6 && view.brushLineWidthPoints == 9 &&
                  view.discardLineWidthPoints == 2, "关闭样式记忆仍须应用用户设置及两点划除线宽")
        view.tool = .brush
        view.chooseColor(.white)
        view.tool = .ellipse
        try check(view.annotationColor == .blue, "工具栏改色应保持其他工具的颜色")

        func draw(_ tool: ScreenshotAnnotationTool, from start: CGPoint, to end: CGPoint) {
            view.tool = tool
            view.mouseDown(with: mouse(.leftMouseDown, start, view, panel, option: false))
            if start != end {
                view.mouseDragged(with: mouse(.leftMouseDragged, end, view, panel, option: false))
            }
            view.mouseUp(with: mouse(.leftMouseUp, end, view, panel, option: false))
        }
        draw(.highlighter, from: CGPoint(x: 70, y: 70), to: CGPoint(x: 220, y: 70))
        draw(.arrow, from: CGPoint(x: 70, y: 120), to: CGPoint(x: 220, y: 120))
        draw(.number, from: CGPoint(x: 300, y: 70), to: CGPoint(x: 300, y: 70))
        guard view.annotations.count == 3,
              case .highlighter(_, 11, _) = view.annotations[0].shape,
              case .sizedArrow(let tail, let tip, .rounded, let width, let scale) = view.annotations[1].shape,
              case .number(_, 1, _, 3) = view.annotations[2].shape else {
            throw Failure.failed("荧光笔、箭头和数字标记应使用设置中的线宽绘制")
        }
        try check(abs(ScreenshotArrowGeometry.effectiveShaftWidth(from: tail, to: tip,
            minimumWidth: width) * scale - 4) < 0.001, "箭头默认线宽使用点作为单位")
        try check(view.annotations.map(\.color) == [.teal, .green, .orange], "新元素保留各工具的实际颜色")

        view.tool = .text
        view.startElementTextInput()
        let field = view.subviews.compactMap { $0 as? NSTextField }.first!
        field.stringValue = "标注"
        _ = field.sendAction(field.action!, to: field.target)
        guard case .styledText(_, "标注", _, .outlinedShadow, 2.5)? = view.annotations.last?.shape else {
            throw Failure.failed("文字标注应保存设置中的描边宽度")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(view.annotations)
        defaults.set(5, forKey: preferences.defaultWidthKey(for: .text))
        view.loadToolDefaults(from: defaults)
        try check(try encoder.encode(view.annotations) == before, "修改默认样式不能改变已有标注")
    }

    @MainActor private static func discardMark() throws {
        let (view, panel) = canvas()
        defer { panel.contentView = nil }
        view.tool = .discard
        view.strokePixelsPerPoint = 1
        let start = CGPoint(x: 90, y: 180), end = CGPoint(x: 490, y: 240)
        view.mouseDown(with: mouse(.leftMouseDown, start, view, panel, option: false))
        view.mouseDragged(with: mouse(.leftMouseDragged, end, view, panel, option: false))
        view.mouseUp(with: mouse(.leftMouseUp, end, view, panel, option: false))
        guard view.annotations.count == 1,
              case .styledRectangleWithRadius(let rect, .discard, 2, _) = view.annotations[0].shape
        else { throw Failure.failed("拖动应创建独立的划除标注") }
        try check(rect == CGRect(x: 90, y: 180, width: 400, height: 60)
            && view.rectangleStyle == .roundedOutline, "划除应覆盖拖动范围并拥有独立的工具状态")

        let bitmap = NSBitmapImageRep(cgImage: try view.renderedImage())
        func green(_ x: Int, _ y: Int) -> CGFloat {
            bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y)!.usingColorSpace(.deviceRGB)!.greenComponent
        }
        let cross = green(290, 210), tint = green(290, 225), outside = green(290, 260)
        try check(cross < tint - 0.25 && tint < outside && tint > 0.8,
                  "中央叉号应突出，淡底下应保留原画面")
        for x in [130, 450] {
            try check(green(x, 186) < 0.60 && green(x, 234) < 0.60,
                      "狭长标注中的两条斜线应延伸到四角附近")
        }
        let borderPixels = (175...185).filter { green(290, $0) < 0.60 }.count
        let crossPixels = (190...200).filter { green(190, $0) < 0.60 }.count
        try check(borderPixels == 2 && crossPixels == borderPixels, "外框和叉号默认共用两点线宽")

        let grab = CGPoint(x: 210, y: 232), drop = CGPoint(x: 240, y: 242)
        view.mouseDown(with: mouse(.leftMouseDown, grab, view, panel, option: false))
        view.mouseDragged(with: mouse(.leftMouseDragged, drop, view, panel, option: false))
        view.mouseUp(with: mouse(.leftMouseUp, drop, view, panel, option: false))
        guard view.annotations.count == 1,
              case .styledRectangleWithRadius(let moved, .discard, _, _) = view.annotations[0].shape
        else { throw Failure.failed("从淡底区域拖动应移动原划除标注") }
        try check(moved == rect.offsetBy(dx: 30, dy: 10), "划除标注应随拖动整体移动")
        view.undo()
        guard case .styledRectangleWithRadius(let restored, .discard, _, _)? = view.annotations.first?.shape
        else { throw Failure.failed("撤销后应保留划除标注") }
        try check(restored == rect, "撤销应恢复划除位置")
    }

    private static func discardOpacity() throws {
        let context = CGContext(data: nil, width: 440, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 20, y: 20, width: 400, height: 60)
        ScreenshotRectangleStyle.discard.draw(in: rect, radius: 4, width: 4, ink: .red, context: context)
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        func opacity(_ x: Int, _ y: Int) -> CGFloat {
            bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y)!.alphaComponent
        }

        let strokeOpacity: CGFloat = 0.8
        let fillOpacity: CGFloat = 0.08
        let strokeOverFill = strokeOpacity + (1 - strokeOpacity) * fillOpacity
        try check(abs(opacity(220, 18) - strokeOpacity) < 0.01, "划除边框应为约 80% 不透明")
        try check(abs(opacity(220, 67) - fillOpacity) < 0.01, "划除淡底应保持原来的透明度")
        for (x, y) in [(220, 21), (120, 35), (220, 50), (32, 21)] {
            try check(abs(opacity(x, y) - strokeOverFill) < 0.02,
                      "划除线条单独与叠合处应使用相同透明度")
        }
    }

    @MainActor private static func optionDrag() throws {
        let (view, panel) = canvas()
        defer { panel.contentView = nil }
        let rect = CGRect(x: 100, y: 100, width: 100, height: 60)
        view.elementFixture([.filledRectangle(rect)])
        let start = CGPoint(x: 150, y: 130), end = CGPoint(x: 230, y: 180)
        view.mouseDown(with: mouse(.leftMouseDown, start, view, panel))
        view.mouseUp(with: mouse(.leftMouseUp, start, view, panel))
        try check(view.annotations.count == 1 && !view.canUndo, "Option click must not duplicate")
        view.mouseDown(with: mouse(.leftMouseDown, start, view, panel))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 190, y: 150), view, panel))
        view.mouseDragged(with: mouse(.leftMouseDragged, end, view, panel, option: false))
        try check(view.annotations.count == 2, "one drag must create exactly one copy even after Option is released")
        view.mouseUp(with: mouse(.leftMouseUp, end, view, panel, option: false))
        guard case .filledRectangle(let original) = view.annotations[0], case .filledRectangle(let duplicate) = view.annotations[1] else { throw Failure.failed("drag copy lost shapes") }
        try check(original == rect && duplicate == rect.offsetBy(dx: 80, dy: 50) && view.selectedElementForSmoke == 1,
            "Option drag must preserve original and select the moved copy")
        view.undo(); try check(view.annotations.count == 1, "one undo must undo the whole drag-copy")
        view.redo(); try check(view.annotations.count == 2, "redo must restore the duplicate")
        view.elementFixture([.filledRectangle(rect)])
        view.mouseDown(with: mouse(.leftMouseDown, start, view, panel))
        view.mouseDragged(with: mouse(.leftMouseDragged, end, view, panel))
        try check(view.cancelPendingAnnotation() && view.annotations.count == 1 && !view.canUndo,
            "Esc cancellation must discard the provisional copy without an undo entry")
        view.mouseUp(with: mouse(.leftMouseUp, end, view, panel))
        try check(view.annotations.count == 1, "mouse-up after cancellation must not recreate the copy")
        view.elementFixture([.filledRectangle(rect)])
        let corner = CGPoint(x: rect.maxX, y: rect.maxY), resized = CGPoint(x: rect.maxX + 40, y: rect.maxY + 20)
        view.mouseDown(with: mouse(.leftMouseDown, corner, view, panel))
        view.mouseDragged(with: mouse(.leftMouseDragged, resized, view, panel))
        view.mouseUp(with: mouse(.leftMouseUp, resized, view, panel))
        guard case .filledRectangle(let square) = view.annotations[0] else { throw Failure.failed("resize lost shape") }
        try check(view.annotations.count == 1 && square.width == square.height, "Option handle drag must retain constrained resizing")
        view.elementFixture([.filledRectangle(rect)])
        let nearCorner = CGPoint(x: corner.x + 10, y: corner.y)
        view.mouseDown(with: mouse(.leftMouseDown, nearCorner, view, panel))
        view.mouseDragged(with: mouse(.leftMouseDragged, resized, view, panel))
        view.mouseUp(with: mouse(.leftMouseUp, resized, view, panel))
        guard view.annotations.count == 1, case .filledRectangle(let enlarged) = view.annotations[0] else {
            throw Failure.failed("Option resize must retain the existing grip hit area outside the mark")
        }
        try check(enlarged.width == enlarged.height, "near-handle Option resize must remain constrained")
        view.elementFixture([.number(start, 7, 16)])
        view.mouseDown(with: mouse(.leftMouseDown, start, view, panel))
        view.mouseDragged(with: mouse(.leftMouseDragged, end, view, panel))
        view.mouseUp(with: mouse(.leftMouseUp, end, view, panel))
        guard view.annotations.count == 2, case .number(let center, let label, let radius, _) = view.annotations[1] else {
            throw Failure.failed("small numbered mark must allow Option body copying instead of grabbing its nearby resize handle")
        }
        try check(center == end && label == 7 && radius == 16, "number copy must preserve label and size")
    }

    @MainActor private static func inputIsolation(_ board: NSPasteboard) throws {
        let (view, panel) = canvas()
        defer { panel.contentView = nil }
        view.elementFixture([.rectangle(CGRect(x: 50, y: 100, width: 90, height: 60))])
        try check(view.copySelectedElement(to: board), "fixture copy failed")
        view.isInputSuspended = true
        try check(!view.handleElementClipboardShortcut(key(9, in: panel), pasteboard: board), "new screenshot must suspend clipboard edits")
        view.isInputSuspended = false
        view.beginCrop()
        try check(!view.pasteElement(from: board), "crop mode must not paste elements")
        view.cancelCrop()
        view.elementFixture([.rectangle(CGRect(x: 50, y: 100, width: 90, height: 60))])
        view.startElementTextInput()
        let count = board.changeCount
        try check(!view.handleElementClipboardShortcut(key(8, in: panel), pasteboard: board)
            && !view.handleElementClipboardShortcut(key(9, in: panel), pasteboard: board)
            && board.changeCount == count, "text input must keep native copy/paste and IME behavior")
        view.discardText()
        board.clearContents(); board.setData(Data("invalid".utf8), forType: ScreenshotAnnotationCanvas.elementPasteboardType)
        try check(!view.pasteElement(from: board) && view.annotations.count == 1, "invalid private data must not mutate the canvas")
        view.elementFixture([], selected: nil)
        let before = board.changeCount
        try check(!view.copySelectedElement(to: board) && board.changeCount == before, "copy with no selection must preserve the clipboard")
    }
}

extension ScreenshotAnnotationCanvas {
    fileprivate func imageForElementSmoke() -> CGImage { image }
}
