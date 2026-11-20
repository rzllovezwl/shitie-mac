// Appended to the production canvas by VerifyTestBuild. All images, files,
// pasteboards and hidden windows below are synthetic; no screen is captured.
extension ScreenshotAnnotationCanvas {
    @MainActor func checkDirectionalShapeResize() {
        let rect = CGRect(x: 100, y: 90, width: 80, height: 60)
        for item in [ScreenshotAnnotation.styledRectangleWithRadius(rect, style: .roundedOutline, width: 4, radius: 4),
                     .styledEllipse(rect, style: .outline, width: 4)] {
            for handle in [ElementHandle.topRight, .topLeft, .bottomRight, .bottomLeft, .right, .left, .top, .bottom] {
                let result = changed(item, handle: handle, delta: CGPoint(x: 30, y: 15), modifiers: [.option])
                let next = bounds(of: result)
                check(next.width == next.height, "Option resize must remain square")
                switch handle {
                case .topRight: check(next.minX == rect.minX && next.minY == rect.minY)
                case .topLeft: check(next.maxX == rect.maxX && next.minY == rect.minY)
                case .bottomRight: check(next.minX == rect.minX && next.maxY == rect.maxY)
                case .bottomLeft: check(next.maxX == rect.maxX && next.maxY == rect.maxY)
                case .right: check(next.minX == rect.minX && next.midY == rect.midY)
                case .left: check(next.maxX == rect.maxX && next.midY == rect.midY)
                case .top: check(next.minY == rect.minY && next.midX == rect.midX)
                case .bottom: check(next.maxY == rect.maxY && next.midX == rect.midX)
                default: preconditionFailure()
                }
            }
        }
    }
}

@main struct ScreenshotPenStickerSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        for color in [ScreenshotAnnotationColor.red, .blue, .green, .white] {
            let image = color.toolbarPalette
            var rect = CGRect(x: 0, y: 0, width: 24, height: 24)
            let bitmap = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
            // Sample after compositing into an explicit sRGB context.
            // NSBitmapImageRep.colorAt otherwise reinterprets sRGB bytes as
            // calibrated RGB, introducing an artificial colour difference.
            let context = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8,
                bytesPerRow: 96, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: 24, height: 24))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            let offset = 12 * 96 + 12 * 4
            let expected = color.color.usingColorSpace(.sRGB)!
            check(abs(CGFloat(bytes[offset]) / 255 - expected.redComponent) < 0.01 &&
                  abs(CGFloat(bytes[offset + 1]) / 255 - expected.greenComponent) < 0.01 &&
                  abs(CGFloat(bytes[offset + 2]) / 255 - expected.blueComponent) < 0.01,
                  "palette body must use the current annotation colour")
            // Check the tiny vector holes at 4x size, avoiding edge pixels
            // introduced when a 2.5-point circle is rasterised at 1x.
            var enlargedRect = CGRect(x: 0, y: 0, width: 96, height: 96)
            let enlarged = image.cgImage(forProposedRect: &enlargedRect, context: nil, hints: nil)!
            let holeContext = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
                bytesPerRow: 384, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            holeContext.draw(enlarged, in: CGRect(x: 0, y: 0, width: 96, height: 96))
            let holePixels = holeContext.data!.assumingMemoryBound(to: UInt8.self)
            for (x, y) in [(28, 40), (48, 28), (66, 38)] {
                check(holePixels[y * 384 + x * 4 + 3] <= 1,
                      "the three palette dots must be transparent cutouts")
            }
            if color == .blue {
                let edge = 12 * 96 + 3 * 4
                check(bytes[edge + 3] > 200 &&
                      abs(CGFloat(bytes[edge]) / 255 - expected.redComponent)
                      + abs(CGFloat(bytes[edge + 1]) / 255 - expected.greenComponent)
                      + abs(CGFloat(bytes[edge + 2]) / 255 - expected.blueComponent) > 0.3,
                      "palette must retain a contrasting outside outline")
            }
        }
        let base = bitmap(width: 600, height: 400, transparent: false)
        let canvas = ScreenshotAnnotationCanvas(image: base, contentInset: 0)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        canvas.strokePixelsPerPoint = 2
        canvas.checkDirectionalShapeResize()
        canvas.tool = .pen
        let a = CGPoint(x: 70, y: 60), b = CGPoint(x: 260, y: 210), c = CGPoint(x: 470, y: 100)
        click(a, canvas, panel)
        canvas.mouseDown(with: event(.leftMouseDown, b, panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 300, y: 260), panel))
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 300, y: 260), panel))
        click(c, canvas, panel)
        check(canvas.isBuildingPenPath && canvas.annotations.isEmpty && canvas.hasChanges)
        canvas.undo(); canvas.redo()
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        guard case .pen(let nodes, let width, let closed) = canvas.annotations.first else { preconditionFailure("pen not committed") }
        check(nodes.count == 3 && nodes[1].incoming != nil && nodes[1].outgoing != nil && width == 8 && !closed)
        var curves = 0
        ScreenshotPenGeometry.path(nodes, closed: false).applyWithBlock { if $0.pointee.type == .addCurveToPoint { curves += 1 } }
        check(curves == 2, "two cubic segments must retain their tangents")
        drag(b, CGPoint(x: 280, y: 230), canvas, panel)
        guard case .pen(let moved, _, _) = canvas.annotations[0] else { preconditionFailure() }
        check(moved[1].point == CGPoint(x: 280, y: 230) && moved[1].outgoing == CGPoint(x: 320, y: 280))
        drag(CGPoint(x: 320, y: 280), CGPoint(x: 335, y: 295), canvas, panel)
        guard case .pen(let controlled, _, _) = canvas.annotations[0] else { preconditionFailure() }
        check(controlled[1].outgoing == CGPoint(x: 335, y: 295) && controlled[1].point == moved[1].point)
        let penPixels = pixels(try canvas.renderedImage())
        check(penPixels != pixels(base))
        let payload = try canvas.editPayload(maximumBytes: 32 * 1024 * 1024)!
        let reopened = ScreenshotAnnotationCanvas(image: base, contentInset: 0)
        reopened.frame = canvas.frame
        check(reopened.loadDocument(payload.annotationData))
        check(pixels(try reopened.renderedImage()) == penPixels, "pen export/reopen changed pixels")
        canvas.undo(); canvas.redo()
        check(pixels(try canvas.renderedImage()) == penPixels)

        // A separate path closes by clicking its first anchor, not by
        // flattening a cubic segment or completing the screenshot.
        canvas.tool = .pen
        let first = CGPoint(x: 400, y: 280)
        click(first, canvas, panel); click(CGPoint(x: 500, y: 310), canvas, panel)
        click(CGPoint(x: 450, y: 370), canvas, panel); click(first, canvas, panel)
        guard case .pen(let polygon, _, let isClosed) = canvas.annotations.last else { preconditionFailure() }
        check(isClosed && polygon.count == 3)
        click(CGPoint(x: 40, y: 340), canvas, panel)
        check(canvas.cancelPendingAnnotation() && !canvas.isBuildingPenPath && canvas.annotations.count == 2)

        let source = bitmap(width: 200, height: 100, transparent: true)
        let png = NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])!
        let jpeg = NSBitmapImageRep(cgImage: source).representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"100\"><rect width=\"100\" height=\"100\" fill=\"red\"/></svg>".utf8)
        for data in [png, jpeg, svg] {
            let asset = ScreenshotStickerAsset.decode(data)!
            check(asset.width == 200 && asset.height == 100 && !asset.pngData.isEmpty)
        }
        check(ScreenshotStickerAsset.decode(Data("not an image".utf8)) == nil)
        let board = NSPasteboard(name: NSPasteboard.Name("ClipHoookStickerSmoke-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        check(board.setData(png, forType: .png), "named pasteboard fixture must accept PNG")
        let asset = ScreenshotStickerAsset.fromPasteboard(board)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ClipHoookSticker-\(UUID().uuidString).svg")
        try svg.write(to: file)
        check(ScreenshotStickerAsset.fromFile(file) != nil)
        try FileManager.default.removeItem(at: file)

        let stickerCanvas = ScreenshotAnnotationCanvas(image: base, contentInset: 0)
        panel.contentView = stickerCanvas; stickerCanvas.frame = canvas.frame
        stickerCanvas.prepareSticker(asset)
        drag(CGPoint(x: 80, y: 70), CGPoint(x: 280, y: 170), stickerCanvas, panel)
        guard case .sticker(let rect, let embedded) = stickerCanvas.annotations[0] else { preconditionFailure() }
        check(rect == CGRect(x: 80, y: 70, width: 200, height: 100) && embedded.id == asset.id)
        drag(CGPoint(x: 180, y: 120), CGPoint(x: 210, y: 140), stickerCanvas, panel)
        guard case .sticker(let movedRect, _) = stickerCanvas.annotations[0] else { preconditionFailure() }
        check(movedRect.origin == CGPoint(x: 110, y: 90))
        drag(CGPoint(x: movedRect.maxX, y: movedRect.maxY),
             CGPoint(x: movedRect.maxX + 80, y: movedRect.maxY + 40), stickerCanvas, panel)
        guard case .sticker(let resized, _) = stickerCanvas.annotations[0] else { preconditionFailure() }
        check(resized.width == 280 && resized.height == 140 && resized.origin == movedRect.origin)
        let stickerPixels = pixels(try stickerCanvas.renderedImage())
        check(stickerPixels != pixels(base))
        let stickerPayload = try stickerCanvas.editPayload(maximumBytes: 32 * 1024 * 1024)!
        let restored = ScreenshotAnnotationCanvas(image: base, contentInset: 0)
        restored.frame = canvas.frame
        check(restored.loadDocument(stickerPayload.annotationData))
        check(pixels(try restored.renderedImage()) == stickerPixels, "embedded image lost on reopen")
        stickerCanvas.undo(); stickerCanvas.redo()
        check(pixels(try stickerCanvas.renderedImage()) == stickerPixels)
        panel.contentView = nil
        print("Pen/sticker smoke passed: cubic nodes, tangent editing, closure, undo, PNG/JPEG/SVG imports, clipboard, placement, resize, embedded reopen and Option anchors")
    }

    @MainActor static func bitmap(width: Int, height: Int, transparent: Bool) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor((transparent ? NSColor.clear : .white).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if transparent { context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height)) }
        return context.makeImage()!
    }

    @MainActor static func event(_ type: NSEvent.EventType, _ point: CGPoint, _ panel: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    @MainActor private static func click(_ point: CGPoint, _ canvas: ScreenshotAnnotationCanvas, _ panel: NSWindow) {
        canvas.mouseDown(with: event(.leftMouseDown, point, panel)); canvas.mouseUp(with: event(.leftMouseUp, point, panel))
    }
    @MainActor private static func drag(_ a: CGPoint, _ b: CGPoint, _ canvas: ScreenshotAnnotationCanvas, _ panel: NSWindow) {
        canvas.mouseDown(with: event(.leftMouseDown, a, panel)); canvas.mouseDragged(with: event(.leftMouseDragged, b, panel))
        canvas.mouseUp(with: event(.leftMouseUp, b, panel))
    }
    static func pixels(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
}

private func check(_ condition: Bool, _ message: String = "Pen/sticker assertion failed") { precondition(condition, message) }
