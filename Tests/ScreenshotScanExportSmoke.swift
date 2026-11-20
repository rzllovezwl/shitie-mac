// Appended to the production canvas by VerifyTestBuild so private rendering
// code can be checked without opening a window or reading the user's screen.
@main
struct ScreenshotScanExportSmoke {
    enum Failure: Error { case failed(String) }
    @MainActor
    static func main() throws {
        try checkAnnotationPreferences()
        try checkTranslationLayout()
        try checkTransparentWindowPreview()
        try checkFrozenTextPixels()
        try ScreenshotAnnotationCanvas.checkAnnotationAppearance()
        try ScreenshotAnnotationCanvas.checkEditorZoom()
        try ScreenshotAnnotationCanvas.checkMagnifier()
        try ScreenshotAnnotationCanvas.checkSelectionConstraints()
        let context = CGContext(data: nil, width: 240, height: 160,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        context.setFillColor(NSColor.systemRed.cgColor)
        context.fill(CGRect(x: 30, y: 20, width: 70, height: 45))
        let canvas = ScreenshotAnnotationCanvas(image: context.makeImage()!, contentInset: 0)
        canvas.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        canvas.toggleTranslation([ScreenshotTranslatedLine(
            sourceRect: CGRect(x: 0.05, y: 0.55, width: 0.8, height: 0.25), text: "Hello"
        )])
        let before = try pixels(canvas.renderedImage())
        for message in ["正在识别文字…", "正在识别并翻译…"] {
            canvas.scanMessage = message
            canvas.layoutSubtreeIfNeeded()
            guard let overlay = canvas.subviews.first(where: { $0 is ScanLoadingView }) as? ScanLoadingView else {
                throw Failure.failed("处理时应出现独立扫描显示层")
            }
            try check(overlay.message == message && overlay.hitTest(CGPoint(x: 30, y: 30)) == nil,
                      "扫描层应显示当前操作，且不能阻挡选区或 Esc 对应控件")
            try check(try pixels(canvas.renderedImage()) == before,
                      "扫描显示层不能写入带译文的截图像素")
            canvas.scanMessage = nil
            try check(!canvas.subviews.contains { $0 is ScanLoadingView },
                      "完成、取消或失败后必须移除扫描层")
        }
        print("Screenshot scan export smoke passed: transparent window preview, export alpha, loading labels, pointer passthrough and cleanup")
    }

    @MainActor static func checkAnnotationPreferences() throws {
        let suite = "ClipHoookAnnotationStartupSmoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ScreenshotAnnotationTool.arrow.rawValue,
                     forKey: ScreenshotAnnotationPreferences.lastToolKey)
        try check(ScreenshotAnnotationPreferences.startupTool(in: defaults) == .rectangle,
                  "升级后默认应使用矩形，不能被旧的最后工具覆盖")
        defaults.set(ScreenshotAnnotationTool.brush.rawValue,
                     forKey: ScreenshotAnnotationPreferences.startupToolKey)
        try check(ScreenshotAnnotationPreferences.startupTool(in: defaults) == .brush,
                  "应支持指定任意默认工具")
        defaults.set(ScreenshotAnnotationPreferences.rememberLastTool,
                     forKey: ScreenshotAnnotationPreferences.startupToolKey)
        defaults.set(false, forKey: ScreenshotAnnotationPreferences.remembersToolAndStyleKey)
        try check(ScreenshotAnnotationPreferences.startupTool(in: defaults) == .arrow,
                  "记住工具应独立于样式记忆开关")
        defaults.set(900, forKey: ScreenshotAnnotationPreferences.startupToolKey)
        try check(ScreenshotAnnotationPreferences.startupTool(in: defaults) == .rectangle,
                  "未知默认工具应安全回退到矩形")
    }

    @MainActor static func checkTranslationLayout() throws {
        let source = CGRect(x: 20, y: 20, width: 240, height: 20)
        let text = "I will change it to press and drag to place the magnifying glass, and let go to determine the size."
        let inputs = [ScreenshotTranslatedLine(sourceRect: source, text: text),
            ScreenshotTranslatedLine(sourceRect: CGRect(x: 20, y: 120, width: 260, height: 24),
                                     text: "Updating magnifier drag handling")]
        let output = ScreenshotTranslationLayout.arrange(inputs,
            imageSize: CGSize(width: 700, height: 250), pixelsPerPoint: 1)
        let line = output[0]
        try check(line.fontSize! >= 20 && line.sourceRect.height > source.height,
                  "长译文应利用空白换行，不能缩成很小的单行")
        try check(!line.sourceRect.intersects(output[1].sourceRect), "译文不能挤到下一段文字上")
        let font = line.fontSize!
        let content = line.sourceRect.insetBy(dx: ScreenshotTranslationLayout.padding(for: font),
                                             dy: ScreenshotTranslationLayout.padding(for: font))
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(
            ScreenshotTranslationLayout.attributed(text, size: font)), CFRange(),
            CGPath(rect: content, transform: nil), nil)
        try check(CTFrameGetVisibleStringRange(frame).length == (text as NSString).length,
                  "放大并换行后译文必须完整，不能截断")
        let doubled = ScreenshotTranslationLayout.arrange(inputs.map {
            ScreenshotTranslatedLine(sourceRect: CGRect(x: $0.sourceRect.minX * 2,
                y: $0.sourceRect.minY * 2, width: $0.sourceRect.width * 2,
                height: $0.sourceRect.height * 2), text: $0.text)
        }, imageSize: CGSize(width: 1400, height: 500), pixelsPerPoint: 2)
        try check(abs(doubled[0].fontSize! - line.fontSize! * 2) < 0.1,
                  "原生像素倍率变化时译文视觉字号应一致")
        let old = try JSONDecoder().decode(ScreenshotTranslatedLine.self,
            from: Data("{\"sourceRect\":[[20,20],[240,20]],\"text\":\"legacy\"}".utf8))
        try check(old.fontSize == nil, "旧译文布局没有字号字段时仍应可读取")
        print("Screenshot translation and preferences smoke passed: readable wrapping, complete text, no overlap, Retina and startup choices")
    }

    @MainActor
    static func checkTransparentWindowPreview() throws {
        let rect = CGRect(x: 0, y: 0, width: 240, height: 160)
        let context = CGContext(data: nil, width: 240, height: 160,
                                bitsPerComponent: 8, bytesPerRow: 240 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 8,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 30, dy: 30),
                              cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        let canvas = ScreenshotAnnotationCanvas(image: context.makeImage()!, contentInset: 0)
        canvas.frame = rect
        let exportBefore = try pixels(canvas.renderedImage())
        let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 240 * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
        // Represent an unrelated window behind the screenshot's transparent
        // corners and shadow. It must not show through the editing canvas.
        NSColor.green.setFill()
        rect.fill()
        canvas.draw(rect)
        NSGraphicsContext.restoreGraphicsState()
        for point in [CGPoint(x: 12, y: 12), CGPoint(x: 24, y: 80)] {
            let sample = preview.colorAt(x: Int(point.x), y: Int(point.y))!.usingColorSpace(.deviceRGB)!
            try check(abs(sample.redComponent - sample.greenComponent) < 0.01
                      && abs(sample.greenComponent - sample.blueComponent) < 0.01
                      && sample.alphaComponent > 0.99,
                      "窗口透明边缘不能透出原窗口形成重影")
        }
        let exported = try canvas.renderedImage()
        let corner = NSBitmapImageRep(cgImage: exported).colorAt(x: 12, y: 12)!
        try check(corner.alphaComponent == 0, "标注底色不能进入窗口截图的透明边缘")
        try check(try pixels(exported) == exportBefore, "显示背景不能改变保存的截图或系统阴影")
    }
    @MainActor
    static func checkFrozenTextPixels() throws {
        // Use real antialiased glyphs, fractional selections and an offset
        // display. Neither the editor handoff nor PNG export may resample them.
        for scale: CGFloat in [1, 1.5, 2] {
            let screen = CGRect(x: 1440, y: -200, width: 320, height: 200)
            let width = Int(screen.width * scale), height = Int(screen.height * scale)
            let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            for (y, weight) in [(70.0, NSFont.Weight.regular), (105.0, .light)] {
                let text = NSAttributedString(string: "截图文字 Text 123 ilmn",
                    attributes: [.font: NSFont.systemFont(ofSize: 15, weight: weight),
                                 .foregroundColor: NSColor.black])
                context.textPosition = CGPoint(x: 30, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            let source = context.makeImage()!
            let frozen = MacScreenshotFrozenDisplay(screenFrame: screen, image: source)
            let selection = CGRect(x: 1461.25, y: -149.75, width: 276.5, height: 100.5)
            let crop = try frozen.crop(selection)
            try check(abs(crop.frame.width * scale - CGFloat(crop.image.width)) < 0.00001 &&
                      abs(crop.frame.height * scale - CGFloat(crop.image.height)) < 0.00001,
                      "分数选区的编辑框须与实际像素一致，不能把文字压缩回未对齐的范围")
            let local = CGRect(x: selection.minX - screen.minX,
                y: screen.maxY - selection.maxY, width: selection.width, height: selection.height)
            let expected = source.cropping(to: MacScreenshotGeometry.pixelCropRect(local,
                imageSize: CGSize(width: width, height: height), displaySize: screen.size))!
            let canvas = ScreenshotAnnotationCanvas(image: crop.image, contentInset: 0)
            canvas.frame = CGRect(origin: .zero, size: crop.frame.size)
            let rendered = try canvas.renderedImage()
            try check(rendered === crop.image, "未标注的文字截图须直接沿用原像素")
            let encoded = try MacScreenshotCapture.encode(rendered, maximumBytes: 10_000_000)
            let decoded = CGImageSourceCreateImageAtIndex(
                CGImageSourceCreateWithData(encoded.data as CFData, nil)!, 0, nil)!
            try check(encoded.type == "public.png" && decoded.width == expected.width &&
                      decoded.height == expected.height, "文字截图必须无损保存并保留像素尺寸")
            try check(try rgbaPixels(decoded) == rgbaPixels(expected),
                      "保存后的字形边缘必须逐像素一致，不能加重或叠出副本")
        }
        print("Frozen text pixels smoke passed: 1x/1.5x/2x glyphs, fractional bounds, native crop and lossless PNG")
    }

    static func rgbaPixels(_ image: CGImage) throws -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    static func pixels(_ image: CGImage) throws -> Data {
        guard let data = image.dataProvider?.data else { throw Failure.failed("No image pixels") }
        return data as Data
    }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.failed(message) }
    }
}

extension ScreenshotAnnotationCanvas {
    static func checkEditorZoom() throws {
        let check = ScreenshotScanExportSmoke.check
        let viewport = CGRect(x: 0, y: 0, width: 620, height: 400)
        for (width, height) in [(100, 900), (1600, 300)] {
            let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let canvas = ScreenshotAnnotationCanvas(image: context.makeImage()!)
            let document = ScreenshotAnnotationDocument(version: 3, imageWidth: width, imageHeight: height,
                annotations: [.filledRectangle(CGRect(x: 20, y: 40, width: 30, height: 35))])
            try check(canvas.loadDocument(JSONEncoder().encode(document)), "测试标注应能加载")
            let before = try ScreenshotScanExportSmoke.pixels(canvas.renderedImage())
            let scroll = ScreenshotAnnotationScrollView(canvas: canvas)
            scroll.frame = viewport
            scroll.layout()
            let fitted = scroll.convert(canvas.imageRect, from: canvas)
            try check(viewport.contains(fitted) && abs(fitted.midX - viewport.midX) < 1 &&
                      abs(fitted.midY - viewport.midY) < 1 &&
                      abs(fitted.width / fitted.height - CGFloat(width) / CGFloat(height)) < 0.001,
                      "竖图和横图都应完整、居中、等比适配")
            let cursor = CGPoint(x: viewport.midX, y: viewport.midY + 35)
            let anchor = canvas.imagePoint(canvas.convert(cursor, from: nil))
            scroll.zoom(by: 1, at: cursor)
            try check(abs(scroll.magnification - 2) < 0.001, "捏合应放大画布")
            if height > width, let anchor, let next = canvas.imagePoint(canvas.convert(cursor, from: nil)) {
                try check(abs(next.y - anchor.y) < 2, "放大时应保持指针下的原图位置")
            }
            scroll.frame.size = CGSize(width: 550, height: 310)
            scroll.layout()
            try check(abs(scroll.magnification - 2) < 0.001, "缩放后调整窗口应保留当前倍率")
            scroll.zoom(by: -0.5, at: cursor)
            let refitted = scroll.convert(canvas.imageRect, from: canvas)
            try check(scroll.magnification == 1 && scroll.bounds.contains(refitted) &&
                      abs(refitted.midY - scroll.bounds.midY) < 1, "缩回时应适配新的窗口大小")
            scroll.zoom(by: -0.5, at: cursor)
            let smaller = scroll.convert(canvas.imageRect, from: canvas)
            try check(scroll.magnification == 0.5 && smaller.width < refitted.width &&
                      smaller.height < refitted.height && abs(smaller.midX - scroll.bounds.midX) < 1 &&
                      abs(smaller.midY - scroll.bounds.midY) < 1, "适配窗口后仍应能缩小并居中")
            scroll.zoom(by: -0.5, at: cursor)
            scroll.zoom(by: -0.5, at: cursor)
            try check(scroll.magnification == 0.25, "缩小应止于适配倍率的 25%")
            try check(try ScreenshotScanExportSmoke.pixels(canvas.renderedImage()) == before,
                      "预览缩放和窗口调整不能改变导出的图像和标注")
        }
        print("Screenshot annotation zoom smoke passed: fit, centering, pointer anchor, resize and export pixels")
    }

    static func checkMagnifier() throws {
        let check = ScreenshotScanExportSmoke.check
        let pixels = ScreenshotScanExportSmoke.pixels
        let width = 240
        let height = 180
        let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor)
        let sourceDetail = CGRect(x: 118, y: 84, width: 8, height: 12)
        context.fill(sourceDetail)
        let source = context.makeImage()!
        func makeCanvas() -> ScreenshotAnnotationCanvas {
            let canvas = ScreenshotAnnotationCanvas(image: source, contentInset: 0)
            canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
            canvas.tool = .magnifier
            return canvas
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint,
                   flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func sample(_ image: CGImage, x: Int, y: Int = 90) -> NSColor {
            NSBitmapImageRep(cgImage: image).colorAt(x: x, y: height - 1 - y)!.usingColorSpace(.sRGB)!
        }
        func drag(_ canvas: ScreenshotAnnotationCanvas, from start: CGPoint, to end: CGPoint,
                  flags: NSEvent.ModifierFlags = []) {
            canvas.mouseDown(with: event(.leftMouseDown, start, flags: flags))
            canvas.mouseDragged(with: event(.leftMouseDragged, end, flags: flags))
            canvas.mouseUp(with: event(.leftMouseUp, end, flags: flags))
        }
        let canvas = makeCanvas()
        let start = CGPoint(x: 70, y: 60)
        let end = CGPoint(x: 190, y: 120)
        canvas.mouseDown(with: event(.leftMouseDown, start))
        canvas.mouseUp(with: event(.leftMouseUp, start))
        try check(canvas.annotations.isEmpty && !canvas.canUndo,
                  "单击不应放置放大镜或增加撤销记录")
        drag(canvas, from: start, to: end)
        guard let lens = canvas.annotations.first,
              case .ellipticalMagnifier(let rect, let zoom) = lens else {
            throw ScreenshotScanExportSmoke.Failure.failed("拖动应创建椭圆放大镜")
        }
        try check(rect == CGRect(x: 70, y: 60, width: 120, height: 60) && zoom == 2,
                  "镜片应按拖动矩形确定宽高，而非固定正圆")
        try check(canvas.handles(for: lens).count == 9, "镜片应有八个尺寸锚点和一个倍率菱形")
        let magnified = try canvas.renderedImage()
        try check(sample(magnified, x: 114).redComponent < 0.05 &&
                  sample(magnified, x: 114).blueComponent > 0.95 &&
                  sample(magnified, x: 210).redComponent > 0.98,
                  "椭圆内应等比放大两倍，外部保持原图")
        let move = canvas.changed(lens, handle: .body, delta: CGPoint(x: 0, y: 20))
        let resize = canvas.changed(move, handle: .right, delta: CGPoint(x: 10, y: 0))
        try check(resize.magnifierGeometry?.rect == CGRect(x: 70, y: 80, width: 130, height: 60),
                  "侧锚点只应调整对应轴，不能强制正圆")
        let tiny = canvas.changed(lens, handle: .topRight, delta: CGPoint(x: -118, y: -58))
        try check(tiny.magnifierGeometry?.rect.size == CGSize(width: 2, height: 2),
                  "调整镜片时不应有 18 点的最小尺寸")
        let resizedCircle = canvas.changed(lens, handle: .right,
            delta: CGPoint(x: 20, y: 0), modifiers: .shift).magnifierGeometry!.rect
        try check(resizedCircle.width == resizedCircle.height,
                  "放置后按 Shift 调整镜片锚点也应保持正圆")
        let payload = try canvas.editPayload(maximumBytes: 5_000_000)!
        let reopened = makeCanvas()
        try check(reopened.loadDocument(payload.annotationData) &&
                  pixels(reopened.renderedImage()) == pixels(magnified), "椭圆镜片应可保存和重开")
        let diamond = canvas.handles(for: lens).first { $0.0 == .magnification }!.1
        drag(canvas, from: diamond, to: CGPoint(x: diamond.x, y: diamond.y + 50))
        try check(canvas.annotations[0].magnifierGeometry!.magnification > 3.5,
                  "上拖蓝色菱形应提高倍率")
        canvas.undo()
        try check(canvas.annotations[0].magnifierGeometry!.magnification == 2,
                  "一次倍率拖动应只占一个撤销步骤")
        canvas.undo()
        try check(try pixels(canvas.renderedImage()) == pixels(source), "放大镜应支持撤销")
        for (flags, end, expected) in [
            (NSEvent.ModifierFlags(), CGPoint(x: 65, y: 43), CGSize(width: 5, height: 3)),
            (NSEvent.ModifierFlags.shift, CGPoint(x: 100, y: 60), CGSize(width: 40, height: 40))
        ] {
            let draft = makeCanvas()
            drag(draft, from: CGPoint(x: 60, y: 40), to: end, flags: flags)
            try check(draft.annotations.first?.magnifierGeometry?.rect.size == expected,
                      "小镜片应不被放大，Shift 才绘制正圆")
        }
        let compact = makeCanvas()
        let compactRect = CGRect(x: 70, y: 65, width: 18, height: 20)
        drag(compact, from: compactRect.origin, to: CGPoint(x: compactRect.maxX, y: compactRect.maxY))
        let middle = CGPoint(x: compactRect.midX, y: compactRect.midY)
        compact.mouseMoved(with: event(.mouseMoved, middle))
        drag(compact, from: middle, to: CGPoint(x: middle.x + 20, y: middle.y + 12))
        let movedRect = compactRect.offsetBy(dx: 20, dy: 12)
        try check(compact.annotations.first?.magnifierGeometry?.rect == movedRect,
                  "小镜片的中心应能移动标注，不能被密集的锚点当成缩放")
        let rightGrip = compact.handles(for: compact.annotations[0]).first { $0.0 == .right }!.1
        drag(compact, from: rightGrip, to: CGPoint(x: rightGrip.x + 9, y: rightGrip.y))
        try check(compact.annotations.first?.magnifierGeometry?.rect == CGRect(
            x: movedRect.minX, y: movedRect.minY, width: movedRect.width + 9, height: movedRect.height
        ), "外扩后的锚点应按拖动增量改变原尺寸")
        let document = ScreenshotAnnotationDocument(version: 7, imageWidth: width, imageHeight: height,
            annotations: [lens, .obscure(sourceDetail, mode: .mosaic, strength: 5)])
        try check(canvas.loadDocument(JSONEncoder().encode(document)), "遮盖和放大镜应可同时恢复")
        let redacted = try canvas.renderedImage()
        try check(sample(redacted, x: 114).redComponent > 0.5,
                  "源像素经过遮盖时，镜片不能恢复原来的蓝色细节")
        // The refracted bezel must also respect obscured source pixels.
        let edgeContext = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        edgeContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let edgeDetail = CGRect(x: 98, y: 86, width: 8, height: 8)
        edgeContext.setFillColor(NSColor.blue.cgColor)
        edgeContext.fill(edgeDetail)
        let edgeCanvas = ScreenshotAnnotationCanvas(image: edgeContext.makeImage()!, contentInset: 0)
        let edgeDocument = ScreenshotAnnotationDocument(version: 7, imageWidth: width, imageHeight: height,
            annotations: [lens, .obscure(edgeDetail, mode: .mosaic, strength: 5)])
        try check(edgeCanvas.loadDocument(JSONEncoder().encode(edgeDocument)), "镜框遮盖测试应能恢复")
        try check(sample(edgeCanvas.renderedImage(), x: 72).redComponent > 0.5,
                  "玻璃镜框折射也必须使用遮盖后的像素")

        let clearContext = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        clearContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let clearCanvas = ScreenshotAnnotationCanvas(image: clearContext.makeImage()!, contentInset: 0)
        let clearDocument = ScreenshotAnnotationDocument(version: 7, imageWidth: width, imageHeight: height,
            annotations: [lens])
        try check(clearCanvas.loadDocument(JSONEncoder().encode(clearDocument)), "透明镜片应能恢复")
        let transparentLens = try clearCanvas.renderedImage()
        try check(sample(transparentLens, x: 130).alphaComponent < 0.01 &&
                  sample(transparentLens, x: 15, y: 15).alphaComponent < 0.01 &&
                  sample(transparentLens, x: 72).alphaComponent > 0.05,
                  "玻璃只应出现在镜框，镜片中心和远处透明像素应保持透明")
        for area in [CGRect(x: 60, y: 40, width: 2, height: 2),
                     CGRect(x: 20, y: 70, width: 180, height: 2)] {
            let tinyDocument = ScreenshotAnnotationDocument(version: 7, imageWidth: width, imageHeight: height,
                annotations: [.ellipticalMagnifier(area, magnification: 2)])
            try check(clearCanvas.loadDocument(JSONEncoder().encode(tinyDocument)), "微小镜片应能恢复")
            let result = try clearCanvas.renderedImage()
            try check(result.width == width && result.height == height, "玻璃镜框不能引入最小镜片尺寸")
        }
        let legacy = ScreenshotAnnotationDocument(version: 6, imageWidth: width, imageHeight: height,
            annotations: [.magnifier(center: CGPoint(x: 130, y: 90), radius: 40)])
        try check(canvas.loadDocument(JSONEncoder().encode(legacy)), "旧版正圆镜片应仍可读取")
        let editedLegacy = canvas.changed(canvas.annotations[0], handle: .magnification,
                                         delta: CGPoint(x: 0, y: -50))
        try check(editedLegacy.magnifierGeometry!.magnification < 2,
                  "旧版镜片也应可以下拖菱形减小倍率")
        let rectangular = makeCanvas()
        rectangular.chooseMagnifierStyle(.roundedRectangle)
        drag(rectangular, from: start, to: end)
        guard let rectangle = rectangular.annotations.first,
              case .rectangularMagnifier(let rectangleRect, let rectangleZoom) = rectangle else {
            throw ScreenshotScanExportSmoke.Failure.failed("矩形模式拖动应放置矩形放大镜")
        }
        let style = ScreenshotMagnifierStyle.roundedRectangle
        try check(rectangleRect == rect && rectangleZoom == 2 &&
                  rectangular.handles(for: rectangle).count == 9,
                  "矩形镜片应沿用尺寸锚点和倍率菱形")
        let roundedPath = style.path(in: rect)
        try check(!roundedPath.contains(CGPoint(x: rect.minX + 0.1, y: rect.minY + 0.1)) &&
                  roundedPath.contains(CGPoint(x: rect.minX + 6, y: rect.minY + 6)),
                  "矩形镜片应有轻微圆角，但保持较大的矩形内容区域")
        let nearCorner = CGPoint(x: 80, y: 70)
        try check(rectangular.bodyHit(rectangle, at: nearCorner, tolerance: 0) != nil &&
                  rectangular.bodyHit(lens, at: nearCorner, tolerance: 0) == nil,
                  "矩形内部靠近角的位置应可命中，不能沿用椭圆的点击范围")
        for changed in [
            rectangular.changed(rectangle, handle: .body, delta: CGPoint(x: 5, y: 5)),
            rectangular.changed(rectangle, handle: .right, delta: CGPoint(x: 15, y: 0)),
            rectangular.changed(rectangle, handle: .magnification, delta: CGPoint(x: 0, y: 30)),
            rectangular.changed(rectangle, handle: .topRight, delta: CGPoint(x: -118, y: -58))
        ] {
            try check(changed.magnifierGeometry?.style == .roundedRectangle,
                      "移动、缩放及调整倍率都必须保留矩形镜片形状")
        }
        let square = makeCanvas()
        square.magnifierStyle = .roundedRectangle
        drag(square, from: CGPoint(x: 60, y: 40), to: CGPoint(x: 100, y: 60), flags: .shift)
        try check(square.annotations.first?.magnifierGeometry?.rect.size == CGSize(width: 40, height: 40),
                  "矩形镜片按 Shift 绘制正方形")
        let rectangularImage = try rectangular.renderedImage()
        let rectangularPayload = try rectangular.editPayload(maximumBytes: 5_000_000)!
        let rectangularDocument = try JSONDecoder().decode(ScreenshotAnnotationDocument.self,
                                                          from: rectangularPayload.annotationData)
        try check(rectangularDocument.version == 9 && reopened.loadDocument(rectangularPayload.annotationData) &&
                  pixels(reopened.renderedImage()) == pixels(rectangularImage),
                  "矩形镜片保存重开后必须保持形状、倍率和绘制效果")
        rectangular.selectedIndex = 0
        rectangular.chooseMagnifierStyle(.ellipse)
        try check(rectangular.annotations[0].magnifierGeometry?.style == .ellipse &&
                  rectangular.annotations[0].magnifierGeometry?.rect == rect,
                  "已选镜片切换形状时必须保留位置和大小")
        rectangular.undo()
        try check(rectangular.annotations[0].magnifierGeometry?.style == .roundedRectangle,
                  "形状切换必须支持撤销")
        let rectangularMask = ScreenshotAnnotationDocument(version: 9, imageWidth: width, imageHeight: height,
            annotations: [rectangle, .obscure(sourceDetail, mode: .mosaic, strength: 5),
                          .obscure(edgeDetail, mode: .mosaic, strength: 5)])
        try check(edgeCanvas.loadDocument(JSONEncoder().encode(rectangularMask)), "矩形镜片遮盖应能恢复")
        let rectangularRedacted = try edgeCanvas.renderedImage()
        try check(sample(rectangularRedacted, x: 114).redComponent > 0.5 &&
                  sample(rectangularRedacted, x: 72).redComponent > 0.5,
                  "矩形镜片中心和玻璃镜框都不能恢复遮盖过的细节")
        let clearRectangle = ScreenshotAnnotationDocument(version: 9, imageWidth: width, imageHeight: height,
            annotations: [rectangle])
        try check(clearCanvas.loadDocument(JSONEncoder().encode(clearRectangle)), "透明矩形镜片应能恢复")
        let transparentRectangle = try clearCanvas.renderedImage()
        try check(sample(transparentRectangle, x: 130).alphaComponent < 0.01 &&
                  sample(transparentRectangle, x: 15, y: 15).alphaComponent < 0.01 &&
                  sample(transparentRectangle, x: 72).alphaComponent > 0.05,
                  "矩形镜片只在玻璃边框绘制，不填充透明中心")
        print("Screenshot magnifier smoke passed: ellipse and rounded rectangle, glass rim, masked refraction, alpha preservation, Shift constraints, tiny lens, handles, zoom, shape switching, undo and legacy reopen")
    }

    static func checkSelectionConstraints() throws {
        let check = ScreenshotScanExportSmoke.check
        let bitmap = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let canvas = ScreenshotAnnotationCanvas(image: bitmap.makeImage()!, contentInset: 0)
        container.addSubview(canvas)
        canvas.frame = CGRect(x: 100, y: 80, width: 201, height: 160)
        canvas.selectionStartFrame = canvas.frame
        canvas.selectionStartPoint = .zero
        canvas.selectionDrag = .right
        let square = canvas.adjustedSelection(to: CGPoint(x: 20, y: 30), modifiers: .option)
        try check(square.width == square.height && square.minX == canvas.frame.minX &&
                  square.midY == canvas.frame.midY, "Option 调整选区应固定对侧并沿拖动方向等宽高调整")
        canvas.selectionDrag = .move
        canvas.selectionConstraintHorizontal = nil
        let moved = canvas.adjustedSelection(to: CGPoint(x: 80, y: 30), modifiers: .shift)
        try check(moved.minX == 180 && moved.minY == 80 && moved.size == canvas.frame.size,
                  "Shift 移动截图应锁定单轴且不改变截图大小")
        canvas.selectionDrag = .topRight
        canvas.selectionConstraintHorizontal = nil
        let resized = canvas.adjustedSelection(to: CGPoint(x: 40, y: 15), modifiers: .shift)
        try check(resized.width == 241 && resized.height == 160,
                  "Shift 拖动截图角点应仅调整主轴尺寸")
    }

    static func checkAnnotationAppearance() throws {
        let size = 192
        let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: size, height: size))
        bitmap.setFillColor(NSColor.black.cgColor)
        for x in stride(from: 13, to: size, by: 17) {
            bitmap.fill(CGRect(x: x, y: 0, width: 5, height: size))
        }
        let source = bitmap.makeImage()!
        let canvas = ScreenshotAnnotationCanvas(image: source, contentInset: 0)
        let check = ScreenshotScanExportSmoke.check
        let pixels = ScreenshotScanExportSmoke.pixels
        try check(canvas.annotationColor == .red && canvas.obscureMode == .blur, "Incorrect defaults")

        let area = CGRect(x: 24, y: 32, width: 124, height: 98)
        let ink = CGRect(x: 4, y: 4, width: 12, height: 12)
        let document = ScreenshotAnnotationDocument(version: 3, imageWidth: size, imageHeight: size,
            annotations: [.mosaic(area), .filledRectangle(ink)])
        try check(canvas.loadDocument(JSONEncoder().encode(document)), "Legacy mosaic must still reopen")
        canvas.selectedIndex = 1
        canvas.chooseColor(.blue)
        let painted = NSBitmapImageRep(cgImage: try canvas.renderedImage())
        let blue = painted.colorAt(x: 9, y: size - 10)!.usingColorSpace(.deviceRGB)!
        try check(blue.blueComponent > blue.redComponent + 0.3, "Color must reach exported pixels")

        canvas.selectedIndex = 0
        var results: Set<Data> = []
        for mode in ScreenshotObscureMode.allCases {
            for level in [1, 5] {
                canvas.chooseObscure(mode, strength: level)
                let rendered = try canvas.renderedImage()
                let rep = NSBitmapImageRep(cgImage: rendered)
                let original = NSBitmapImageRep(cgImage: source)
                func changed(_ x: Int) -> Bool {
                    let actual = rep.colorAt(x: x, y: 90)!.usingColorSpace(.sRGB)!
                    let expected = original.colorAt(x: x, y: 90)!.usingColorSpace(.sRGB)!
                    return abs(actual.redComponent - expected.redComponent) > 1.0 / 255
                }
                try check((30..<140).contains { x in
                    changed(x)
                },
                    "Both effects must change the selected pixels")
                try check((160..<180).allSatisfy { x in
                    !changed(x)
                },
                    "Obscuring must leave pixels outside the selection untouched")
                results.insert(try pixels(rendered))
            }
        }
        try check(results.count == 4, "Modes and strengths must produce distinct results")
        let payload = try canvas.editPayload(maximumBytes: 1024 * 1024)!
        let reopened = ScreenshotAnnotationCanvas(image: source, contentInset: 0)
        try check(reopened.loadDocument(payload.annotationData), "Appearance must reopen for editing")
        try check(try pixels(reopened.renderedImage()) == pixels(canvas.renderedImage()),
                  "Reopening must preserve color and effect strength")
        let whiteHighlight = ScreenshotAnnotation.highlighter(
            [CGPoint(x: 8, y: 90), CGPoint(x: 64, y: 90)], 8).colored(.white)
        let whiteDocument = ScreenshotAnnotationDocument(version: 4, imageWidth: size,
            imageHeight: size, annotations: [whiteHighlight])
        try check(reopened.loadDocument(JSONEncoder().encode(whiteDocument)), "White must reopen")
        let highlighted = NSBitmapImageRep(cgImage: try reopened.renderedImage())
        let whiteStroke = highlighted.colorAt(x: 15, y: 101)!.usingColorSpace(.sRGB)!
        try check(whiteStroke.redComponent > 0.2, "White highlighter must be visible on dark pixels")

        let drawing = ScreenshotAnnotationCanvas(image: source, contentInset: 0)
        drawing.frame = CGRect(x: 0, y: 0, width: size, height: size)
        drawing.tool = .highlighter
        let start = CGPoint(x: 30, y: 60)
        let end = CGPoint(x: 130, y: 110)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: .shift, timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        drawing.mouseDown(with: event(.leftMouseDown, start))
        drawing.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 50, y: 120)))
        drawing.mouseUp(with: event(.leftMouseUp, end))
        guard case .highlighter(let points, _, let opacity) = drawing.annotations.first?.shape else {
            throw ScreenshotScanExportSmoke.Failure.failed("Shift drag must create a highlighter stroke")
        }
        try check(points == [start, end] && opacity == 50, "Shift must draw a straight 50% stroke")
        let half = try pixels(drawing.renderedImage())
        drawing.setHighlighterOpacity(75, updateSelection: true)
        try check(try pixels(drawing.renderedImage()) != half, "Opacity must update the selected stroke")
        drawing.undo()
        try check(try pixels(drawing.renderedImage()) == half, "Opacity edits must be undoable")

        let spotlightDocument = ScreenshotAnnotationDocument(version: 5, imageWidth: size, imageHeight: size,
            annotations: [.spotlight(CGRect(x: 30, y: 32, width: 35, height: 72)),
                          .spotlight(CGRect(x: 100, y: 32, width: 35, height: 72))])
        try check(drawing.loadDocument(JSONEncoder().encode(spotlightDocument)), "Spotlight must reopen")
        let spotlight = NSBitmapImageRep(cgImage: try drawing.renderedImage())
        func brightness(at x: Int) -> CGFloat {
            spotlight.colorAt(x: x, y: 115)!.usingColorSpace(.sRGB)!.redComponent
        }
        try check(brightness(at: 40) > 0.98 && brightness(at: 110) > 0.98 && brightness(at: 70) < 0.7,
                  "Separate highlighted regions must stay bright with a dimmed surround")
        print("Screenshot appearance smoke passed: palette, legacy mosaic, blur and pixelation strength, clipping, editable reopen")
    }
}
