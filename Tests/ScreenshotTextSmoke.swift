// Compiled together with the production canvas. Only synthetic images and
// hidden windows are used; the user's clipboard and screen are not read.
extension ScreenshotAnnotationCanvas {
    @MainActor func checkIMEComposition() {
        let anchor = CGPoint(x: 42, y: 95)
        beginText(at: imagePoint(anchor)!, viewPoint: anchor, editing: nil, translationLine: nil)
        let field = activeTextField!
        let editor = field.currentEditor() as! NSTextView
        ScreenshotTextSmoke.check(shouldShowTextPlaceholder)
        // A Chinese input method updates marked text without committing it to
        // NSTextField. Do not manually send the control's change notification.
        let blank = ScreenshotTextSmoke.pixels(image)
        for pinyin in ["a", "as'd'f", "zhong'wen"] {
            editor.setMarkedText(pinyin,
                selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            ScreenshotTextSmoke.check(editor.hasMarkedText() && editor.string == pinyin)
            // AppKit can repaint synchronously while updating marked text.
            // Check the resulting hint pixels, not the transient dirty flag.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            ScreenshotTextSmoke.check(!shouldShowTextPlaceholder,
                "Unconfirmed Pinyin must hide the entire hint, not just overlap its first characters")
            ScreenshotTextSmoke.check(editor.hasMarkedText() && editor.string == pinyin,
                "Refreshing the hint/layout must preserve IME composition and candidate text")
            let baseline = editorBaseline(in: field)!
            ScreenshotTextSmoke.check(hypot(baseline.x - anchor.x, baseline.y - anchor.y) < 0.01,
                "Marked text must use the same baseline as the input hint")
            let draft = ScreenshotTextSmoke.context(width: image.width, height: image.height)
            render(in: draft, includeDraft: true)
            ScreenshotTextSmoke.check(ScreenshotTextSmoke.pixels(draft.makeImage()!) == blank,
                "No placeholder glyphs may remain on the canvas beneath the IME editor")
        }
        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        ScreenshotTextSmoke.check(!editor.hasMarkedText() && editor.string == "中文"
                                  && !shouldShowTextPlaceholder)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.deleteBackward(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        ScreenshotTextSmoke.check(editor.string.isEmpty && shouldShowTextPlaceholder,
            "Deleting all text should restore the hint")
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        discardText()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        ScreenshotTextSmoke.check(activeTextField == nil && !shouldShowTextPlaceholder,
            "Cancelling composition must not revive the hint or an old editor")
    }

    @MainActor func checkPlaceholderToTyping() {
        let anchor = CGPoint(x: 42, y: 95)
        textStyle = .plain
        beginText(at: imagePoint(anchor)!, viewPoint: anchor, editing: nil, translationLine: nil)
        let field = activeTextField!
        let editor = field.currentEditor() as! NSTextView
        let hint = "输入文字，回车添加"
        let before = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: before)
        // Use AppKit's actual insertion path, including the control delegate.
        // Assigning editor.string and manually notifying misses empty input.
        editor.insertText(hint, replacementRange: NSRange(location: 0, length: 0))
        let after = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: after)
        let minimumX = Int((anchor.x + 3) * CGFloat(before.pixelsWide) / bounds.width)
        let hintBounds = ScreenshotTextSmoke.inkBounds(before.cgImage!, minimumX: minimumX)
        let inputBounds = ScreenshotTextSmoke.inkBounds(after.cgImage!, minimumX: minimumX)
        ScreenshotTextSmoke.check(!hintBounds.isNull && !inputBounds.isNull,
            "Missing placeholder/input pixels: \(hintBounds) vs \(inputBounds); field=\(field.frame); text=\(editor.string)")
        ScreenshotTextSmoke.check(abs(hintBounds.minX - inputBounds.minX) <= 1
            && abs(hintBounds.minY - inputBounds.minY) <= 1
            && abs(hintBounds.maxX - inputBounds.maxX) <= 1
            && abs(hintBounds.maxY - inputBounds.maxY) <= 1,
            "Placeholder and first typed text move: \(hintBounds) vs \(inputBounds)")
        discardText()
        textStyle = .outlinedShadow
    }

    @MainActor func checkSavedEmoji() throws {
        let document = ScreenshotAnnotationDocument(version: 5, imageWidth: image.width, imageHeight: image.height,
            annotations: [.styledText(CGPoint(x: 100, y: 100), "❤️", fontSize: 28, style: .plain)])
        ScreenshotTextSmoke.check(loadDocument(try JSONEncoder().encode(document)))
        let annotated = try renderedImage()
        ScreenshotTextSmoke.check(!ScreenshotTextSmoke.redGlyphBounds(annotated).isNull,
                                  "Previously saved emoji must still render")
    }

    @MainActor func checkTextEditor(scale: CGFloat) throws {
        let anchor = CGPoint(x: 42, y: 95)
        let imageAnchor = imagePoint(anchor)!
        beginText(at: imageAnchor, viewPoint: anchor, editing: nil, translationLine: nil)
        guard let field = activeTextField,
              let editor = field.currentEditor() as? NSTextView else {
            preconditionFailure("Inline text entry must use the native field editor")
        }
        ScreenshotTextSmoke.check(abs(field.font!.pointSize - 18) < 0.01)
        for text in ["Hello", "中文 English", "  保留前后空格  ", String(repeating: "宽", count: 35)] {
            editor.string = text
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                              object: field))
            let displayed = editorBaseline(in: field)!
            ScreenshotTextSmoke.check(hypot(displayed.x - anchor.x, displayed.y - anchor.y) < 0.01,
                         "Typing must retain the same image baseline, including long lines")
            let attributes = editor.textStorage!.attributes(at: 0, effectiveRange: nil)
            let font = attributes[.font] as! NSFont
            ScreenshotTextSmoke.check(abs(font.pointSize * pointsToImage - textFontSize) < 0.01)
            let draft = ScreenshotTextSmoke.context(width: image.width, height: image.height)
            render(in: draft, includeDraft: true)
            ScreenshotTextSmoke.check(ScreenshotTextSmoke.pixels(draft.makeImage()!)
                != ScreenshotTextSmoke.pixels(image), "The outline must be visible while typing")
        }
        editor.string = "  中文 English  "
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        // Compare AppKit's actual field-editor pixels with the committed
        // canvas, not just two invocations of the export renderer.
        let typing = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: typing)
        commitText()
        selectedIndex = nil
        let committed = bitmapImageRepForCachingDisplay(in: bounds)!
        cacheDisplay(in: bounds, to: committed)
        let typingBounds = ScreenshotTextSmoke.redGlyphBounds(typing.cgImage!)
        let savedBounds = ScreenshotTextSmoke.redGlyphBounds(committed.cgImage!)
        ScreenshotTextSmoke.check(!typingBounds.isNull && !savedBounds.isNull)
        ScreenshotTextSmoke.check(abs(typingBounds.minX - savedBounds.minX) <= 1
            && abs(typingBounds.minY - savedBounds.minY) <= 1
            && abs(typingBounds.maxX - savedBounds.maxX) <= 1
            && abs(typingBounds.maxY - savedBounds.maxY) <= 1,
            "Native typing and committed text glyph bounds differ: \(typingBounds) vs \(savedBounds)")
        if scale == 1, ProcessInfo.processInfo.environment["CLIPHOOK_TEXT_STYLE_PREVIEW"] != nil {
            for (name, rep) in [("typing", typing), ("committed", committed)] {
                try rep.representation(using: .png, properties: [:])!.write(
                    to: URL(fileURLWithPath: "/private/tmp/cliphoook-text-\(name).png"))
            }
        }
        guard case .styledText(let point, let string, let size, let style, _) = annotations.last else {
            preconditionFailure("New text should persist its style")
        }
        ScreenshotTextSmoke.check(point == imageAnchor && abs(size - 18 * scale) < 0.01)
        ScreenshotTextSmoke.check(string == "  中文 English  " && style == .outlinedShadow,
                     "Commit must not trim intentional spaces or change font size/style")
        let firstImage = ScreenshotTextSmoke.pixels(try renderedImage())
        beginText(at: point, viewPoint: viewPoint(point), editing: 0, translationLine: nil)
        ScreenshotTextSmoke.check(abs(activeTextField!.font!.pointSize - 18) < 0.01)
        let editingBaseline = editorBaseline(in: activeTextField!)!
        ScreenshotTextSmoke.check(hypot(editingBaseline.x - anchor.x, editingBaseline.y - anchor.y) < 0.01)
        commitText()
        ScreenshotTextSmoke.check(firstImage == ScreenshotTextSmoke.pixels(try renderedImage()),
                     "Reopening and confirming text must not shift its pixels")
        let moved = changed(annotations[0], handle: .body, delta: CGPoint(x: 25, y: -10))
        guard case .styledText(let movedPoint, _, _, let movedStyle, _) = moved else {
            preconditionFailure("Moving styled text lost its style")
        }
        ScreenshotTextSmoke.check(movedPoint == CGPoint(x: point.x + 25, y: point.y - 10) && movedStyle == style)
        let resized = changed(moved, handle: .topRight, delta: CGPoint(x: 20, y: 20))
        guard case .styledText(_, _, let resizedSize, let resizedStyle, _) = resized else {
            preconditionFailure("Resizing styled text lost its style")
        }
        ScreenshotTextSmoke.check(resizedSize > size && resizedStyle == style)

        for nextStyle in ScreenshotTextStyle.allCases {
            selectedIndex = 0
            chooseTextStyle(nextStyle)
            let appearance = ScreenshotTextSmoke.pixels(try renderedImage())
            let payload = try editPayload(maximumBytes: 5_000_000)!
            let reopened = ScreenshotAnnotationCanvas(image: image)
            ScreenshotTextSmoke.check(reopened.loadDocument(payload.annotationData))
            ScreenshotTextSmoke.check(appearance == ScreenshotTextSmoke.pixels(try reopened.renderedImage()),
                         "All text styles must survive editable-document round trips")
        }
        let highlight = ScreenshotTextSmoke.pixels(try renderedImage())
        undo()
        ScreenshotTextSmoke.check(highlight != ScreenshotTextSmoke.pixels(try renderedImage()),
                     "Changing the selected text style should be undoable")
        redo()
        ScreenshotTextSmoke.check(highlight == ScreenshotTextSmoke.pixels(try renderedImage()))
    }

    @MainActor func checkLegacyText() throws {
        for version in [1, 2] {
            let point = CGPoint(x: 70, y: 100)
            let document = ScreenshotAnnotationDocument(version: version,
                imageWidth: image.width, imageHeight: image.height,
                annotations: [.text(point, "原文字 Hello", fontSize: 26)])
            ScreenshotTextSmoke.check(loadDocument(try JSONEncoder().encode(document)))
            let before = ScreenshotTextSmoke.pixels(try renderedImage())
            beginText(at: point, viewPoint: viewPoint(point), editing: 0, translationLine: nil)
            ScreenshotTextSmoke.check(abs(activeTextField!.font!.pointSize * pointsToImage - 26) < 0.01)
            commitText()
            ScreenshotTextSmoke.check(before == ScreenshotTextSmoke.pixels(try renderedImage()),
                         "Existing plain text must not be restyled or repositioned on open")
            selectedIndex = 0
            chooseTextStyle(.outlinedShadow)
            ScreenshotTextSmoke.check(before != ScreenshotTextSmoke.pixels(try renderedImage()))
            undo()
            ScreenshotTextSmoke.check(before == ScreenshotTextSmoke.pixels(try renderedImage()))
        }
    }
}

@main struct ScreenshotTextSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let image = blank(width: 960, height: 600)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for scale in [CGFloat(1), 1.5, 2] {
                let canvas = ScreenshotAnnotationCanvas(image: image, contentInset: 0)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0,
                    width: 960 / scale, height: 600 / scale), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.isReleasedWhenClosed = false
                window.contentView = canvas
                canvas.checkIMEComposition()
                canvas.checkPlaceholderToTyping()
                try canvas.checkTextEditor(scale: scale)
                try canvas.checkLegacyText()
                window.contentView = nil
            }
        }
        let emojiCanvas = ScreenshotAnnotationCanvas(image: image)
        emojiCanvas.frame = CGRect(x: 0, y: 0, width: 500, height: 350)
        try emojiCanvas.checkSavedEmoji()

        // Independently check that the selected styles have different pixels.
        let images = ScreenshotTextStyle.allCases.map { style -> [UInt8] in
            let context = context(width: 320, height: 80)
            ScreenshotTextRendering.draw("文字 Aa", at: CGPoint(x: 30, y: 30),
                                          size: 28, style: style, in: context)
            return pixels(context.makeImage()!)
        }
        // A thick outline must not cover the foreground fill.
        let plain = context(width: 320, height: 80)
        let outlined = context(width: 320, height: 80)
        for (bitmap, style) in [(plain, ScreenshotTextStyle.plain), (outlined, .outlinedShadow)] {
            ScreenshotTextRendering.draw("文字 Aa", at: CGPoint(x: 30, y: 30), size: 36, style: style, in: bitmap)
        }
        check(redGlyphBounds(plain.makeImage()!) == redGlyphBounds(outlined.makeImage()!),
              "Outline must preserve the full red glyph bounds")
        for i in images.indices {
            for j in images.indices where j > i {
                ScreenshotTextSmoke.check(images[i] != images[j], "Text style previews must be visually different")
            }
        }
        if let output = ProcessInfo.processInfo.environment["CLIPHOOK_TEXT_STYLE_PREVIEW"] {
            let context = context(width: 760, height: 420)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 380, height: 420))
            context.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
            context.fill(CGRect(x: 380, y: 0, width: 380, height: 420))
            for (index, style) in ScreenshotTextStyle.allCases.enumerated() {
                for x in [CGFloat(30), 410] {
                    ScreenshotTextRendering.draw("文字标注 Hello", at: CGPoint(x: x, y: CGFloat(360 - index * 75)),
                        size: 30, style: style, in: context)
                }
            }
            let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
        print("Screenshot text smoke passed: IME composition/candidates/deletion/cancel, placeholder/input/commit at 1x/1.5x/2x in light/dark mode, styles, edit/reopen, undo, legacy text and emoji")
    }

    static func check(_ value: Bool, _ message: String = "Text annotation regression") {
        precondition(value, message)
    }

    static func redGlyphBounds(_ image: CGImage) -> CGRect {
        let data = pixels(image)
        var rect = CGRect.null
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                if Int(data[index]) > Int(data[index + 1]) + 50,
                   Int(data[index]) > Int(data[index + 2]) + 50 {
                    rect = rect.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return rect
    }

    static func inkBounds(_ image: CGImage, minimumX: Int) -> CGRect {
        let data = pixels(image)
        var rect = CGRect.null
        for y in 0..<image.height {
            for x in minimumX..<image.width {
                let index = (y * image.width + x) * 4
                if min(data[index], data[index + 1]) < 235 && data[index + 2] < 235 {
                    rect = rect.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return rect
    }

    static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func blank(width: Int, height: Int) -> CGImage {
        let context = context(width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        let context = context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }
}
