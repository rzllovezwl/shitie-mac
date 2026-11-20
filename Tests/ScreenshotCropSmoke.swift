// Appended to the production canvas. Uses synthetic pixels and an off-screen
// window only; never captures the desktop or modifies the system clipboard.
extension ScreenshotAnnotationCanvas {
    @MainActor fileprivate func addCropCoordinateFixtures() {
        annotations = [
            .number(CGPoint(x: 90, y: 80), 1, 12),
            .pen([ScreenshotPenNode(point: CGPoint(x: 70, y: 60)),
                  ScreenshotPenNode(point: CGPoint(x: 120, y: 90))], width: 5, closed: false),
            .translation([ScreenshotTranslatedLine(
                sourceRect: CGRect(x: 90, y: 55, width: 70, height: 25), text: "示例")])
        ]
    }

    @MainActor fileprivate func cropDrag(_ start: CGPoint, _ end: CGPoint) {
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: convert(viewPoint(point), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window!.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        mouseDown(with: event(.leftMouseDown, start))
        mouseDragged(with: event(.leftMouseDragged, end))
        mouseUp(with: event(.leftMouseUp, end))
    }
}

@main struct ScreenshotCropSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let base = bitmap()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.contentView = nil }
        func attach(_ canvas: ScreenshotAnnotationCanvas) {
            window.contentView = canvas
            canvas.fitEditor(to: CGSize(width: 520, height: 420))
            canvas.onImageSizeChanged = { [weak canvas] in
                canvas?.fitEditor(to: CGSize(width: 520, height: 420))
            }
        }
        let canvas = ScreenshotAnnotationCanvas(image: base)
        attach(canvas)
        canvas.tool = .rectangle
        canvas.cropDrag(CGPoint(x: 70, y: 60), CGPoint(x: 130, y: 100))
        check(canvas.annotations.count == 1, "fixture must be an actual editable rectangle")
        let before = try canvas.renderedImage()
        canvas.beginCrop()
        canvas.cropDrag(CGPoint(x: 40, y: 30), CGPoint(x: 200, y: 150))
        check(canvas.cropRect == CGRect(x: 40, y: 30, width: 160, height: 120))
        check(pixels(try canvas.renderedImage()) == pixels(before), "crop preview must not alter exports")
        // Render the selection and handles off screen as well.
        let viewBitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: viewBitmap)
        check(canvas.applyCrop(), "crop must apply")
        check(canvas.image.width == 160 && canvas.image.height == 120)
        let cropped = try canvas.renderedImage()
        let expected = before.cropping(to: CGRect(x: 40, y: 50, width: 160, height: 120))!
        check(pixels(cropped) == pixels(expected), "crop pixels or annotation origin changed")
        check(canvas.annotations.count == 1, "cropping must keep the rectangle editable")
        let payload = try canvas.editPayload(maximumBytes: 8 * 1024 * 1024)!
        let source = CGImageSourceCreateWithData(payload.baseImageData as CFData, nil)!
        let restored = ScreenshotAnnotationCanvas(image: CGImageSourceCreateImageAtIndex(source, 0, nil)!)
        check(restored.loadDocument(payload.annotationData))
        check(pixels(try restored.renderedImage()) == pixels(cropped), "saved editable crop must reopen unchanged")
        canvas.undo()
        check(canvas.image.width == 300 && canvas.image.height == 200)
        check(pixels(try canvas.renderedImage()) == pixels(before), "undo must restore the image and marks together")
        canvas.undo()
        let unmarked = try canvas.renderedImage()
        check(canvas.annotations.isEmpty && pixels(unmarked) == pixels(base))
        canvas.redo(); canvas.redo()
        check(pixels(try canvas.renderedImage()) == pixels(cropped), "mixed image/annotation redo failed")
        canvas.beginCrop()
        canvas.cropDrag(CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 80))
        canvas.cancelCrop()
        check(pixels(try canvas.renderedImage()) == pixels(cropped), "cancel must keep all pixels")
        canvas.undo(); canvas.redo()
        check(pixels(try canvas.renderedImage()) == pixels(cropped), "cancel must not add an undo step")
        canvas.beginCrop()
        canvas.cropDrag(CGPoint(x: 20, y: 15), CGPoint(x: 100, y: 90))
        check(canvas.applyCrop() && canvas.image.width == 80 && canvas.image.height == 75)
        let secondCrop = try canvas.renderedImage()
        canvas.undo()
        check(pixels(try canvas.renderedImage()) == pixels(cropped), "second crop lost first crop")
        canvas.redo()
        check(pixels(try canvas.renderedImage()) == pixels(secondCrop))

        let geometry = ScreenshotAnnotationCanvas(image: base)
        attach(geometry)
        geometry.addCropCoordinateFixtures()
        geometry.beginCrop()
        geometry.cropDrag(CGPoint(x: 40, y: 30), CGPoint(x: 200, y: 150))
        check(geometry.applyCrop())
        guard case .number(let point, _, let radius, _) = geometry.annotations[0],
              case .pen(let nodes, let width, _) = geometry.annotations[1],
              case .translation(let lines) = geometry.annotations[2] else { preconditionFailure() }
        check(point == CGPoint(x: 50, y: 50) && radius == 12)
        check(nodes.map(\.point) == [CGPoint(x: 30, y: 30), CGPoint(x: 80, y: 60)] && width == 5)
        check(lines[0].sourceRect == CGRect(x: 50, y: 5, width: 70, height: 25),
              "OCR's top-origin coordinates must use the new image height")

        let imageOnly = ScreenshotAnnotationCanvas(image: base)
        attach(imageOnly)
        imageOnly.beginCrop()
        imageOnly.cropDrag(CGPoint(x: 300, y: 200), CGPoint(x: 220, y: 160))
        check(imageOnly.cropRect == CGRect(x: 0, y: 0, width: 220, height: 160), "corner resize failed")
        imageOnly.cropDrag(CGPoint(x: 110, y: 80), CGPoint(x: 200, y: 160))
        check(imageOnly.cropRect == CGRect(x: 80, y: 40, width: 220, height: 160), "move must stay inside image")
        check(imageOnly.applyCrop() && imageOnly.hasChanges && imageOnly.canUndo)
        check(try imageOnly.editPayload(maximumBytes: 8 * 1024 * 1024) == nil,
              "a crop without annotations must not invent editable marks")
        let export = try imageOnly.export(maximumBytes: 8 * 1024 * 1024)
        let exportedSource = CGImageSourceCreateWithData(export.data as CFData, nil)!
        let exported = CGImageSourceCreateImageAtIndex(exportedSource, 0, nil)!
        check(exported.width == 220 && exported.height == 160)
        imageOnly.undo()
        check(!imageOnly.hasChanges && pixels(imageOnly.image) == pixels(base))
        imageOnly.beginCrop()
        check(imageOnly.applyCrop() && !imageOnly.canUndo, "full-image confirmation must be a no-op")
        imageOnly.beginCrop()
        imageOnly.cropDrag(CGPoint(x: 220, y: 170), CGPoint(x: 40, y: 30))
        check(imageOnly.cropRect == CGRect(x: 40, y: 30, width: 180, height: 140), "reverse drag failed")
        imageOnly.isInputSuspended = true
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        imageOnly.keyDown(with: escape)
        check(imageOnly.isCropping, "Esc in a new screenshot must not cancel the old image's crop")
        imageOnly.isInputSuspended = false
        imageOnly.keyDown(with: escape)
        check(!imageOnly.isCropping, "Esc must work again after screenshot interaction ends")

        check(ScreenshotCropGeometry.pixelRect(CGRect(x: CGFloat.infinity, y: 0, width: 4, height: 4),
            in: CGSize(width: 300, height: 200)) == nil)
        check(ScreenshotCropGeometry.pixelRect(CGRect(x: 10, y: 10, width: 0, height: 5),
            in: CGSize(width: 300, height: 200)) == nil)
        check(ScreenshotCropGeometry.pixelRect(CGRect(x: -2, y: 15.4, width: 20.2, height: 30.2),
            in: CGSize(width: 300, height: 200)) == CGRect(x: 0, y: 15, width: 19, height: 31))
        let selection = ScreenshotAnnotationCanvas(image: base, contentInset: 0)
        selection.replaceImage(base.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 120))!,
            from: CGRect(x: 0, y: 0, width: 300, height: 200),
            to: CGRect(x: 0, y: 80, width: 160, height: 120))
        check(!selection.hasChanges && !selection.canUndo,
              "adjusting a fresh screenshot selection is not a destructive image edit")
        print("Screenshot crop smoke passed: pixels, editable marks, OCR origin, undo/redo, reopen, resize/move, export and screenshot input suspension")
    }

    @MainActor static func bitmap() -> CGImage {
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 1200,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        for row in 0..<20 {
            context.setFillColor(NSColor(calibratedRed: CGFloat(row) / 20, green: 0.3, blue: 0.7, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: row * 10, width: 300, height: 10))
        }
        context.clear(CGRect(x: 40, y: 30, width: 15, height: 15))
        return context.makeImage()!
    }

    static func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()!.dataProvider!.data! as Data
    }
    static func check(_ condition: Bool, _ message: String = "Crop assertion failed") {
        precondition(condition, message)
    }
}
