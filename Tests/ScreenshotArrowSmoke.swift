// Appended to the production annotation canvas by VerifyTestBuild. This uses
// synthetic images and hidden windows, without reading the user's screen.
extension ScreenshotAnnotationCanvas {
    @MainActor func arrowDraftImageForSmoke() throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MacScreenshotError.noImage }
        render(in: context, includeDraft: true)
        return context.makeImage()!
    }

    @MainActor func editTextForSmoke() {
        annotations.append(.text(CGPoint(x: 20, y: 30), "旧文字", fontSize: 24))
        beginText(at: CGPoint(x: 20, y: 30), viewPoint: CGPoint(x: 20, y: 30),
                  editing: annotations.count - 1, translationLine: nil)
        let field = subviews.compactMap { $0 as? NSTextField }.first!
        field.stringValue = "新文字"
        _ = field.sendAction(field.action!, to: field.target)
    }
}

@main
struct ScreenshotArrowSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let context = CGContext(data: nil, width: 480, height: 300,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 300))
        let canvas = ScreenshotAnnotationCanvas(image: context.makeImage()!, contentInset: 0)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 480, height: 300)
        check(canvas.tool == .rectangle, "新标注画布默认应选择圆角矩形")
        precondition(canvas.arrowStyle == .rounded, "默认必须是参考图左侧的圆尾实心箭头")
        canvas.tool = .arrow

        let start = CGPoint(x: 220, y: 250)
        let end = CGPoint(x: 40, y: 80)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end, in: panel))
        let draft = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseUp(with: event(.leftMouseUp, at: end, in: panel))
        let firstExport = try canvas.renderedImage()
        let firstPixels = pixels(firstExport)
        precondition(firstPixels == draft, "拖动中的箭头预览和保存结果必须一致")
        guard case .arrow(_, _, let firstStyle, let firstWidth) = canvas.annotations[0] else {
            preconditionFailure("应提交一条箭头标注")
        }
        precondition(firstStyle == .rounded && firstWidth > 0, "每条箭头必须保存自己的样式和宽度")

        canvas.arrowStyle = .sharp
        check(pixels(try canvas.renderedImage()) == firstPixels,
              "切换样式不能修改已经画好的箭头")
        canvas.frame.size = CGSize(width: 240, height: 150)
        check(pixels(try canvas.renderedImage()) == firstPixels,
              "缩放编辑器不能改变已保存箭头的宽度或样式")
        canvas.frame.size = CGSize(width: 480, height: 300)
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 410, y: 260), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 330, y: 70), in: panel))
        let sharpDraft = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 330, y: 70), in: panel))
        let secondExport = try canvas.renderedImage()
        precondition(canvas.annotations.count == 2 && pixels(secondExport) == sharpDraft,
                     "尖尾箭头也应保持预览和导出一致")
        guard case .arrow(_, _, let secondStyle, _) = canvas.annotations[1] else {
            preconditionFailure("应提交第二条箭头")
        }
        precondition(secondStyle == .sharp && sharpDraft != firstPixels,
                     "两种箭头应可同时存在于同一张截图")
        let exported = try canvas.export(maximumBytes: 2_000_000)
        let imageSource = CGImageSourceCreateWithData(exported.data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
        precondition(decoded.width == 480 && decoded.height == 300,
                     "保存和复制图片应保留原始像素尺寸")
        canvas.undo()
        check(pixels(try canvas.renderedImage()) == firstPixels, "撤销第二条应完整恢复第一条")

        for style in [ScreenshotArrowStyle.rounded, .sharp] {
            for end in [CGPoint(x: 160, y: 70), CGPoint(x: -160, y: 70),
                        CGPoint(x: -160, y: -70), CGPoint(x: 160, y: -70),
                        CGPoint(x: 0, y: 160), CGPoint(x: -160, y: 0)] {
                let path = ScreenshotArrowGeometry.path(from: .zero, to: end,
                                                        style: style, shaftWidth: 6)
                precondition(path.contains(CGPoint(x: end.x * 0.5, y: end.y * 0.5)),
                             "不同方向的箭身必须是实心")
                precondition(path.contains(CGPoint(x: end.x * 0.92, y: end.y * 0.92)),
                             "箭头三角头部必须填充，且方向与拖动一致")
                let bounds = path.boundingBoxOfPath
                precondition(!bounds.isEmpty && bounds.width.isFinite && bounds.height.isFinite,
                             "旋转后的箭头不能产生无效路径")
            }
            let short = ScreenshotArrowGeometry.path(from: .zero, to: CGPoint(x: 12, y: 0),
                                                     style: style, shaftWidth: 6)
            precondition(short.contains(CGPoint(x: 10, y: 0)), "短箭头仍应有可见的实心头部")
            precondition(ScreenshotArrowGeometry.path(from: .zero, to: .zero,
                                                     style: style, shaftWidth: 6).isEmpty,
                         "未发生拖动时不能绘制异常箭头")
        }
        let shortRounded = ScreenshotArrowGeometry.path(
            from: .zero, to: CGPoint(x: 100, y: 0), style: .rounded, shaftWidth: 6
        )
        let longRounded = ScreenshotArrowGeometry.path(
            from: .zero, to: CGPoint(x: 1_000, y: 0), style: .rounded, shaftWidth: 6
        )
        precondition(!shortRounded.contains(CGPoint(x: 50, y: 10)) &&
                     longRounded.contains(CGPoint(x: 500, y: 10)),
                     "长箭头的箭杆必须跟随箭头一起变粗")
        precondition(!longRounded.contains(CGPoint(x: 100, y: 10)) &&
                     longRounded.contains(CGPoint(x: 600, y: 10)),
                     "圆尾箭头的箭杆应从尾部向箭头逐渐变粗")
        precondition(!longRounded.contains(CGPoint(x: 998, y: 0)) &&
                     longRounded.contains(CGPoint(x: 975, y: 0)),
                     "圆尾箭头的箭头尖端应有可见圆角，仍保持实心")
        precondition(longRounded.boundingBoxOfPath.height < 105,
                     "长箭头的头部不能随着长度线性增大而显得失衡")

        verifyBezierHeadGeometry()

        canvas.arrowStyle = .bezier
        let curveStart = CGPoint(x: 90, y: 210)
        let curveEnd = CGPoint(x: 385, y: 205)
        canvas.mouseDown(with: event(.leftMouseDown, at: curveStart, in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: curveEnd, in: panel))
        let curveDraft = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseUp(with: event(.leftMouseUp, at: curveEnd, in: panel))
        check(pixels(try canvas.renderedImage()) == curveDraft,
              "贝塞尔箭头的拖动预览与保存结果必须一致")
        guard let curveAnnotation = canvas.annotations.last,
              case .bezierArrow(let savedStart, let originalControl, let savedEnd, _) =
                curveAnnotation else {
            preconditionFailure("贝塞尔箭头应保存可编辑的控制点")
        }
        precondition(savedStart == curveStart && savedEnd == curveEnd,
                     "贝塞尔箭头应保留拖动起点和终点")
        let curveBeforeAdjustment = pixels(try canvas.renderedImage())
        let movedControl = CGPoint(x: curveEnd.x + 40, y: 280)
        canvas.mouseDown(with: event(.leftMouseDown, at: originalControl, in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: movedControl, in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: movedControl, in: panel))
        guard let adjustedAnnotation = canvas.annotations.last,
              case .bezierArrow(_, let adjustedControl, _, _) = adjustedAnnotation else {
            preconditionFailure("拖动控制点后应保留贝塞尔箭头")
        }
        let curveAfterAdjustment = pixels(try canvas.renderedImage())
        check(hypot(adjustedControl.x - movedControl.x,
                    adjustedControl.y - movedControl.y) < 0.01 &&
              curveAfterAdjustment != curveBeforeAdjustment,
              "拖动贝塞尔控制点必须改变曲线和最终图片")
        let ring = ScreenshotBezierArrowGeometry.tailRing(
            from: curveStart, to: curveEnd, minimumWidth: 6
        )
        precondition(ring.rect.contains(curveStart) && ring.strokeWidth > 0,
                     "贝塞尔箭头尾部应保留可见圆圈")
        let adjustedPath = ScreenshotBezierArrowGeometry.path(
            from: curveStart, control: adjustedControl, to: curveEnd, minimumWidth: 6)
        let outline = vertices(adjustedPath)
        let tipIndex = outline.firstIndex(of: curveEnd)!
        let bodyIndex = (tipIndex - 1) / 3
        let bodyPoint = CGPoint(
            x: (outline[bodyIndex].x + outline[outline.count - 1 - bodyIndex].x) / 2,
            y: (outline[bodyIndex].y + outline[outline.count - 1 - bodyIndex].y) / 2)
        let translatedPoint = CGPoint(x: bodyPoint.x + 12, y: bodyPoint.y - 10)
        canvas.mouseDown(with: event(.leftMouseDown, at: bodyPoint, in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: translatedPoint, in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: translatedPoint, in: panel))
        guard case .bezierArrow(let movedStart, let movedCurveControl, let movedEnd, _) =
                canvas.annotations.last else {
            preconditionFailure("大幅弯曲后应能直接拖动实际箭身")
        }
        check(movedStart == CGPoint(x: curveStart.x + 12, y: curveStart.y - 10) &&
              movedCurveControl == CGPoint(x: adjustedControl.x + 12, y: adjustedControl.y - 10) &&
              movedEnd == CGPoint(x: curveEnd.x + 12, y: curveEnd.y - 10),
              "实际曲线的命中区域必须与绘制结果一致，整条箭头一起移动")
        canvas.undo()
        check(pixels(try canvas.renderedImage()) == curveAfterAdjustment,
              "撤销移动应恢复调整后的曲线")
        let curvePayload = try canvas.editPayload(maximumBytes: 2_000_000)!
        let curveBaseSource = CGImageSourceCreateWithData(curvePayload.baseImageData as CFData, nil)!
        let curveBase = CGImageSourceCreateImageAtIndex(curveBaseSource, 0, nil)!
        let reopenedCurve = ScreenshotAnnotationCanvas(image: curveBase, contentInset: 0)
        check(reopenedCurve.loadDocument(curvePayload.annotationData),
              "调整后的贝塞尔箭头应能载入可编辑文档")
        check(pixels(try reopenedCurve.renderedImage()) == curveAfterAdjustment,
              "重开可编辑图片后应保留修正后的贝塞尔头部和曲线")
        canvas.undo()
        check(pixels(try canvas.renderedImage()) == curveBeforeAdjustment,
              "撤销控制点调整应保留贝塞尔箭头的原始形状")
        canvas.redo()
        check(pixels(try canvas.renderedImage()) == curveAfterAdjustment,
              "重做应恢复控制点调整")
        canvas.undo()
        canvas.undo()
        check(pixels(try canvas.renderedImage()) == firstPixels,
              "再次撤销应移除新贝塞尔箭头并保留已有标注")

        // Existing marks must be editable directly under the pointer even
        // while a drawing tool is selected. The edit is one undo step.
        canvas.tool = .rectangle
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 280, y: 40), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 430, y: 140), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 430, y: 140), in: panel))
        precondition(canvas.annotations.count == 2, "应创建矩形标注")
        canvas.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 300, y: 140), in: panel))
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 300, y: 140), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 330, y: 160), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 330, y: 160), in: panel))
        guard case .styledRectangleWithRadius(let movedRect, let defaultRectangleStyle,
                                             _, let radius) = canvas.annotations[1] else {
            preconditionFailure("拖动矩形边框应移动现有矩形")
        }
        check(defaultRectangleStyle == .roundedOutline, "矩形默认应为圆角空心")
        check(radius == 4 * canvas.strokePixelsPerPoint,
              "新矩形的默认圆角应为 4 点")
        check(movedRect.origin == CGPoint(x: 310, y: 60),
              "直接拖动矩形边框应移动矩形，不创建新矩形")
        canvas.mouseMoved(with: event(.mouseMoved, at: CGPoint(x: 460, y: 160), in: panel))
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 460, y: 160), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 475, y: 180), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 475, y: 180), in: panel))
        guard case .styledRectangleWithRadius(let resizedRect, _, _, let resizedRadius) =
                canvas.annotations[1] else {
            preconditionFailure("拖动锚点后应保留矩形")
        }
        check(resizedRect.width == 165 && resizedRect.height == 120 && resizedRadius == radius,
              "拖动右上锚点应调整矩形宽高且不改变圆角")
        canvas.undo()
        guard case .styledRectangleWithRadius(let restoredRect, _, _, _) = canvas.annotations[1] else {
            preconditionFailure("撤销缩放应保留矩形")
        }
        check(restoredRect == movedRect, "调整标注应按操作逐步撤销")
        canvas.redo()
        let editPayload = try canvas.editPayload(maximumBytes: 2_000_000)!
        let baseSource = CGImageSourceCreateWithData(editPayload.baseImageData as CFData, nil)!
        let baseImage = CGImageSourceCreateImageAtIndex(baseSource, 0, nil)!
        let reopened = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        check(reopened.loadDocument(editPayload.annotationData), "应载入保存的可编辑标注")
        guard case .styledRectangleWithRadius(let reopenedRect, let reopenedStyle,
                                             _, let reopenedRadius) = reopened.annotations[1] else {
            preconditionFailure("重开图片后矩形仍应是独立标注")
        }
        check(reopenedRect == resizedRect && reopenedStyle == .roundedOutline &&
              reopenedRadius == radius,
              "重开图片应保持标注的位置、尺寸、样式和圆角")
        check(pixels(try reopened.renderedImage()) == pixels(try canvas.renderedImage()),
              "重开并渲染的图片应与保存前相同")
        try verifyShapeStylesAndGestures(baseImage: baseImage)
        try verifyDirectionalOptionGeometry(baseImage: baseImage)
        try verifySelectionAfterAnnotation()
        try verifyBrushAndDoubleClick()
        try verifyArrowBox(baseImage: baseImage)
        verifyThinArrowHeads()
        let textCanvas = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        textCanvas.editTextForSmoke()
        guard case .text(_, let editedText, let editedSize) = textCanvas.annotations.last else {
            preconditionFailure("双击后的编辑框应更新原文字标注")
        }
        check(textCanvas.annotations.count == 1 && editedText == "新文字" && editedSize == 24,
              "重新编辑文字应修改原元素，保留字号，不新增叠加文字")
        textCanvas.undo()
        guard case .text(_, let originalText, _) = textCanvas.annotations.last else {
            preconditionFailure("文字编辑应支持撤销")
        }
        check(originalText == "旧文字", "撤销文字编辑应恢复原文")
        panel.contentView = nil
        print("Screenshot annotation smoke passed: arrows, rectangle and ellipse shadows, linked rounded-corner spacing, direct element drag and resize, undo/redo and editable reopen")
    }

    @MainActor static func event(_ type: NSEvent.EventType, at point: CGPoint, in panel: NSPanel,
                                 modifiers: NSEvent.ModifierFlags = [],
                                 clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                           windowNumber: panel.windowNumber, context: nil,
                           eventNumber: 1, clickCount: clickCount, pressure: 0)!
    }

    @MainActor static func verifyArrowBox(baseImage: CGImage) throws {
        let frame = CGRect(x: 0, y: 0, width: 480, height: 300)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let canvas = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        panel.contentView = canvas
        defer { panel.contentView = nil }
        canvas.frame = frame
        canvas.strokePixelsPerPoint = 1
        canvas.tool = .arrow
        canvas.arrowStyle = .withRectangle

        let start = CGPoint(x: 60, y: 120)
        let end = CGPoint(x: 305, y: 120)
        canvas.mouseDown(with: event(.leftMouseDown, at: start, in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end, in: panel))
        let preview = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseUp(with: event(.leftMouseUp, at: end, in: panel))
        guard canvas.annotations.count == 1,
              case .arrowBox(let original) = canvas.annotations[0].shape else {
            preconditionFailure("一次拖动应创建一个箭头与矩形组合")
        }
        check(original.rect.contains(end) && original.connection.tail == start && original.radius == 4 &&
              original.connection.corner.x == original.rect.minX &&
              original.connection.corner.y == original.rect.minY + original.radius,
              "自动框出松手的位置，箭头指向圆角弧段")
        verifyArrowBoxGap(original)
        check(preview == pixels(try canvas.renderedImage()), "箭头与矩形的实时预览和导出应一致")

        let independent = ScreenshotAnnotationDocument(version: 6,
            imageWidth: baseImage.width, imageHeight: baseImage.height, annotations: [
                .sizedArrow(original.connection.tail, original.connection.tip,
                    style: .rounded, width: original.arrowWidth, scale: original.arrowScale),
                .styledRectangleWithRadius(original.rect, style: .roundedOutline,
                    width: original.rectangleWidth, radius: original.radius)
            ])
        let reference = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        check(reference.loadDocument(try JSONEncoder().encode(independent)), "应能载入用于比对的普通标注")
        check(preview == pixels(try reference.renderedImage()), "组合的圆角、圆尾和阴影应与普通标注一致")

        func drag(_ from: CGPoint, to: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            canvas.mouseDown(with: event(.leftMouseDown, at: from, in: panel, modifiers: modifiers))
            canvas.mouseDragged(with: event(.leftMouseDragged, at: to, in: panel, modifiers: modifiers))
            canvas.mouseUp(with: event(.leftMouseUp, at: to, in: panel, modifiers: modifiers))
        }
        let corner = CGPoint(x: original.rect.minX, y: original.rect.minY)
        drag(corner, to: CGPoint(x: corner.x - 30, y: corner.y - 28))
        guard case .arrowBox(let resized) = canvas.annotations[0].shape else {
            preconditionFailure("调整矩形后应保持组合")
        }
        check(resized.tail == start && resized.rect.width == original.rect.width + 30 &&
              resized.rect.height == original.rect.height + 28 &&
              resized.connection.corner != original.connection.corner,
              "矩形角点独立缩放，箭尖随圆角移动")
        verifyArrowBoxGap(resized)

        let newTail = CGPoint(x: start.x + 28, y: start.y + 44)
        drag(start, to: newTail)
        guard case .arrowBox(let edited) = canvas.annotations[0].shape else {
            preconditionFailure("调整箭尾后应保持组合")
        }
        check(edited.tail == newTail && edited.rect == resized.rect &&
              edited.connection.tip != resized.connection.tip,
              "拖箭尾改变箭头长度和方向，矩形保持位置和尺寸")
        verifyArrowBoxGap(edited)
        let editedPixels = pixels(try canvas.renderedImage())
        let tip = edited.connection.tip
        let grab = CGPoint(x: (edited.tail.x + tip.x) / 2, y: (edited.tail.y + tip.y) / 2)
        drag(grab, to: CGPoint(x: grab.x + 18, y: grab.y + 24), modifiers: [.option])
        guard canvas.annotations.count == 2, case .arrowBox(let duplicate) = canvas.annotations[1].shape else {
            preconditionFailure("Option 拖动应复制整个组合")
        }
        check(duplicate.rect == edited.rect.offsetBy(dx: 18, dy: 24) &&
              duplicate.tail == CGPoint(x: edited.tail.x + 18, y: edited.tail.y + 24),
              "复制时矩形与箭尾在同一坐标系整体偏移")
        canvas.undo()
        check(pixels(try canvas.renderedImage()) == editedPixels, "一次撤销应移除整个副本")
        let payload = try canvas.editPayload(maximumBytes: 2_000_000)!
        let reopened = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        check(reopened.loadDocument(payload.annotationData), "组合应随可编辑图片保存")
        check(pixels(try reopened.renderedImage()) == editedPixels, "再次打开后应准确还原组合")

        canvas.mouseDown(with: event(.leftMouseDown, at: grab, in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: grab, in: panel))
        let near = CGPoint(x: edited.rect.minX, y: edited.rect.maxY)
        drag(near, to: CGPoint(x: 1, y: 299))
        guard case .arrowBox(let expanded) = canvas.annotations[0].shape else {
            preconditionFailure("矩形覆盖原箭尾的位置后仍应保留组合")
        }
        check(expanded.rect.width > edited.rect.width && frame.contains(expanded.connection.tail) &&
              frame.contains(expanded.connection.tip), "拉到截图边缘也应为箭头保留可见空间")
        verifyArrowBoxGap(expanded)

        for (tail, target) in [(CGPoint(x: 445, y: 260), CGPoint(x: 480, y: 300)),
                               (CGPoint(x: 340, y: 230), CGPoint(x: 354, y: 230)),
                               (CGPoint(x: 40, y: 45), CGPoint(x: 0, y: 0))] {
            let rect = ScreenshotArrowBox.targetRect(from: tail, to: target,
                size: CGSize(width: 108, height: 60), in: frame.insetBy(dx: 2, dy: 2))
            check(frame.contains(rect) && !rect.contains(tail) && !rect.isEmpty,
                  "靠边或短距离拖动也要在画布内留下可见的矩形和箭头")
        }

        let wide = CGRect(x: 40, y: 50, width: 380, height: 20)
        let tall = CGRect(x: 180, y: 30, width: 30, height: 240)
        for rect in [wide, tall] {
            for tail in [CGPoint(x: 20, y: 280), CGPoint(x: 444, y: 284),
                         CGPoint(x: 450, y: 12), CGPoint(x: 5, y: 5),
                         CGPoint(x: rect.midX, y: rect.midY)] {
                let box = ScreenshotArrowBox(tail: tail, rect: rect, arrowWidth: 3,
                    arrowScale: 4, rectangleWidth: 15)
                verifyArrowBoxGap(box)
            }
        }
    }

    private static func verifyArrowBoxGap(_ box: ScreenshotArrowBox) {
        let arrow = box.connection
        let outerX = arrow.corner.x <= box.rect.midX ? box.rect.minX + box.radius : box.rect.maxX - box.radius
        let outerY = arrow.corner.y <= box.rect.midY ? box.rect.minY + box.radius : box.rect.maxY - box.radius
        let nx = (arrow.corner.x - outerX) / box.radius
        let ny = (arrow.corner.y - outerY) / box.radius
        check(abs(hypot(nx, ny) - 1) < 0.001, "箭头应指向圆角弧线")
        let dx = arrow.tip.x - arrow.tail.x, dy = arrow.tip.y - arrow.tail.y
        check(abs(dx * (arrow.corner.y - arrow.tip.y) - dy * (arrow.corner.x - arrow.tip.x)) < 0.001,
              "箭头轴线应自然延伸到圆角")

        let path = box.arrowPath
        check(!path.isEmpty, "调整后应仍有可见的箭头轮廓")
        let clearance = box.rectangleWidth / 2 + box.arrowWidth * 1.7
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            default: count = 0
            }
            for index in 0..<count {
                let point = element.pointee.points[index]
                let distance = (point.x - arrow.corner.x) * nx + (point.y - arrow.corner.y) * ny
                check(distance >= clearance - 0.001, "整条箭头都应在圆角切线以外，并留足与描边的空隙")
            }
        }
    }

    @MainActor static func verifyBrushAndDoubleClick() throws {
        let context = CGContext(data: nil, width: 480, height: 300,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 300))
        let canvas = ScreenshotAnnotationCanvas(image: context.makeImage()!, contentInset: 0)
        canvas.strokePixelsPerPoint = 2
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 500, height: 320),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = container
        canvas.frame = CGRect(x: 10, y: 10, width: 480, height: 300)
        container.addSubview(canvas)
        canvas.tool = .brush
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 70, y: 70), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 100, y: 85), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 130, y: 120), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 130, y: 120), in: panel))
        guard case .brush(let freehandPoints, let freehandWidth) = canvas.annotations[0] else {
            preconditionFailure("自由画笔应保存为独立矢量笔迹")
        }
        check(freehandPoints.count >= 3 && freehandWidth == 8,
              "自由画笔应保留轨迹，默认线宽为 4 点")
        let freehandPixels = pixels(try canvas.renderedImage())
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 250, y: 80),
                                     in: panel, modifiers: [.shift]))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 320, y: 150),
                                        in: panel, modifiers: [.shift]))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 320, y: 150),
                                   in: panel, modifiers: [.shift]))
        guard case .brush(let straightPoints, _) = canvas.annotations[1] else {
            preconditionFailure("Shift 画笔应保存为直线笔迹")
        }
        check(straightPoints.count == 2, "Shift 画笔只保留直线的起点和终点")
        let straightPixels = pixels(try canvas.renderedImage())
        let payload = try canvas.editPayload(maximumBytes: 2_000_000)!
        let source = CGImageSourceCreateWithData(payload.baseImageData as CFData, nil)!
        let reopened = ScreenshotAnnotationCanvas(
            image: CGImageSourceCreateImageAtIndex(source, 0, nil)!, contentInset: 0)
        let loaded = reopened.loadDocument(payload.annotationData)
        let reopenedPixels = pixels(try reopened.renderedImage())
        check(loaded && reopenedPixels == straightPixels,
              "画笔保存并重开后仍可编辑且渲染一致")
        canvas.undo()
        check(pixels(try canvas.renderedImage()) == freehandPixels,
              "撤销 Shift 直线应保留原画笔轨迹")
        var saved = 0
        canvas.onDoubleClick = { saved += 1 }
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 230, y: 200),
                                     in: panel, clickCount: 2))
        check(saved == 1 && canvas.annotations.count == 1,
              "双击截图空白选区应完成保存，不应开始拖动或新绘制")
        panel.contentView = nil
    }

    @MainActor static func verifyShapeStylesAndGestures(baseImage: CGImage) throws {
        let canvas = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        canvas.strokePixelsPerPoint = 2
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 480, height: 300)
        canvas.tool = .rectangle
        check(canvas.rectangleStyle == .roundedOutline && canvas.ellipseStyle == .outline,
              "形状工具应以空心圆角矩形和空心椭圆为默认样式")

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 20, y: 20),
                                     in: panel, modifiers: [.shift]))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 100, y: 80),
                                        in: panel, modifiers: [.shift]))
        let shiftDraft = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 100, y: 80),
                                   in: panel, modifiers: [.shift]))
        guard case .styledRectangleWithRadius(let shiftRect, let shiftStyle,
                                             let shiftWidth, let shiftRadius) =
            canvas.annotations[0] else { preconditionFailure("Shift 应绘制矩形") }
        check(shiftRect.width == 80 && shiftRect.height == 24 &&
              shiftStyle == .roundedOutline && shiftWidth == 8 && shiftRadius == 8,
              "Shift 应锁定主拖动轴，空心矩形默认线宽和圆角应为屏幕 4 点")
        check(shiftDraft == pixels(try canvas.renderedImage()),
              "Shift 约束的实时预览与保存结果应相同")

        canvas.rectangleStyle = .squareFilled
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 120, y: 80),
                                     in: panel, modifiers: [.option, .shift]))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 150, y: 100),
                                        in: panel, modifiers: [.option, .shift]))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 150, y: 100),
                                   in: panel, modifiers: [.option, .shift]))
        guard case .styledRectangleWithRadius(let square, let squareStyle, _, _) =
                canvas.annotations[1] else {
            preconditionFailure("Option 应绘制正方形")
        }
        check(square == CGRect(x: 120, y: 80, width: 30, height: 30) &&
              squareStyle == .squareFilled,
              "Option 应优先于 Shift，固定按下点沿拖动方向绘制等宽高矩形")

        canvas.tool = .ellipse
        canvas.ellipseStyle = .filled
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 230, y: 80),
                                     in: panel, modifiers: [.option]))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 260, y: 110),
                                        in: panel, modifiers: [.option]))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 260, y: 110),
                                   in: panel, modifiers: [.option]))
        guard case .styledEllipse(let circle, let ellipseStyle, _) = canvas.annotations[2] else {
            preconditionFailure("Option 应绘制正圆")
        }
        check(circle == CGRect(x: 230, y: 80, width: 30, height: 30) &&
              ellipseStyle == .filled,
              "Option 绘制的正圆应固定按下点并随元素保存实心样式")

        let beforeScroll = pixels(try canvas.renderedImage())
        check(canvas.adjustStroke(at: CGPoint(x: 60, y: 44), deltaY: 12, timestamp: 1),
              "悬停空心矩形边线时两指滑动应改变线宽")
        check(canvas.adjustStroke(at: CGPoint(x: 60, y: 44), deltaY: 12, timestamp: 1.1),
              "连续两指滑动应继续调整同一条边线")
        guard case .styledRectangleWithRadius(_, _, let wider, let radiusAfterScroll) =
                canvas.annotations[0] else {
            preconditionFailure("线宽调整应保存到矩形元素")
        }
        let afterScroll = pixels(try canvas.renderedImage())
        check(wider > shiftWidth && afterScroll != beforeScroll && radiusAfterScroll == shiftRadius,
              "线宽加粗应改变实际导出像素且保持圆角")
        canvas.undo()
        check(pixels(try canvas.renderedImage()) == beforeScroll,
              "连续线宽调整应合并为一个撤销步骤")
        check(!canvas.adjustStroke(at: CGPoint(x: 145, y: 50), deltaY: 10, timestamp: 2),
              "实心矩形不应响应两指线宽调整")

        canvas.ellipseStyle = .outline
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 320, y: 20), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 420, y: 100), in: panel))
        let ellipseDraft = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 420, y: 100), in: panel))
        guard case .styledEllipse(let ellipse, .outline, let ellipseWidth) = canvas.annotations[3] else {
            preconditionFailure("空心椭圆应保存线宽")
        }
        check(ellipseDraft == pixels(try canvas.renderedImage()), "椭圆阴影的实时预览和保存结果应一致")
        let exported = try canvas.export(maximumBytes: 2_000_000)
        let exportSource = CGImageSourceCreateWithData(exported.data as CFData, nil)!
        let exportImage = CGImageSourceCreateImageAtIndex(exportSource, 0, nil)!
        verifyShapeShadows(in: exportImage, shapes: [(shiftRect, shiftWidth), (square, 0),
                                                  (circle, 0), (ellipse, ellipseWidth)])
        check(canvas.adjustStroke(at: CGPoint(x: 370, y: 100), deltaY: -12, timestamp: 3),
              "空心椭圆边线上下滑动应改变线宽")
        guard case .styledEllipse(_, .outline, let thinnerEllipse) = canvas.annotations[3] else {
            preconditionFailure("线宽调整应保存到椭圆元素")
        }
        check(ellipseWidth == 8 && thinnerEllipse < ellipseWidth,
              "空心椭圆默认线宽应为 4 点，并可用手势调细")
        check(canvas.ellipseLineWidthPoints == thinnerEllipse / 2,
              "调整已有椭圆后，同类新标注应使用调整后的线宽")

        canvas.tool = .arrow
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 250, y: 150), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 440, y: 150), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 440, y: 150), in: panel))
        check(canvas.adjustStroke(at: CGPoint(x: 335, y: 150), deltaY: -12, timestamp: 4),
              "箭杆上两指滑动应调整线宽")
        guard case .sizedArrow(_, _, .rounded, _, let arrowScale) = canvas.annotations[4] else {
            preconditionFailure("箭头线宽应按元素保存")
        }
        check(arrowScale < 1, "箭头应能调到原先自动线宽以下")

        let payload = try canvas.editPayload(maximumBytes: 2_000_000)!
        let reopened = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        check(reopened.loadDocument(payload.annotationData), "新样式的标注文档应能重开")
        check(pixels(try reopened.renderedImage()) == pixels(try canvas.renderedImage()),
              "重开后矩形和椭圆样式、线宽及约束几何应保持一致")

        let savedPixels = pixels(try canvas.renderedImage())
        canvas.rectangleCornerRadiusPoints = 12
        check(pixels(try canvas.renderedImage()) == savedPixels,
              "更改圆角设置不能改变已绘制矩形")
        canvas.tool = .rectangle
        canvas.rectangleStyle = .roundedOutline
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 430, y: 210), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 470, y: 270), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 470, y: 270), in: panel))
        guard case .styledRectangleWithRadius(_, _, _, let changedRadius) = canvas.annotations.last
        else { preconditionFailure("新绘制矩形应保存新的圆角设置") }
        check(changedRadius == 24, "设置为 12 点后，新矩形应保存为 2 倍像素半径")

        let legacyOutline = CGRect(x: 10, y: 170, width: 60, height: 50)
        let legacyFill = legacyOutline.offsetBy(dx: 70, dy: 0)
        let legacyEllipse = legacyOutline.offsetBy(dx: 140, dy: 0)
        let legacy = ScreenshotAnnotationDocument(version: 1, imageWidth: 480,
            imageHeight: 300, annotations: [
                .rectangle(legacyOutline), .filledRectangle(legacyFill), .ellipse(legacyEllipse)
            ])
        let legacyCanvas = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        check(legacyCanvas.loadDocument(try JSONEncoder().encode(legacy)),
              "旧版 v1 可编辑文档仍应载入")
        check(legacyCanvas.annotations.count == 3,
              "旧矩形、实心矩形和椭圆都必须保留")
        verifyShapeShadows(in: try legacyCanvas.renderedImage(), shapes: [
            (legacyOutline, 4), (legacyFill, 0), (legacyEllipse, 4)
        ])
        panel.contentView = nil
    }

    private static func verifyShapeShadows(in image: CGImage, shapes: [(CGRect, CGFloat)]) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        for (rect, outlineWidth) in shapes {
            let y = Int(rect.minY - outlineWidth / 2) - 2
            let sample = bitmap.colorAt(x: Int(rect.midX), y: bitmap.pixelsHigh - 1 - y)!
                .usingColorSpace(.sRGB)!
            check(sample.redComponent > 0.85 && sample.redComponent < 0.992 &&
                  abs(sample.redComponent - sample.greenComponent) < 0.01 &&
                  abs(sample.redComponent - sample.blueComponent) < 0.01,
                  "形状轮廓外应显示柔和的灰色阴影")
        }
    }

    @MainActor static func verifyDirectionalOptionGeometry(baseImage: CGImage) throws {
        let canvas = ScreenshotAnnotationCanvas(image: baseImage, contentInset: 0)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 480, height: 300)

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 120, y: 130),
                                     in: panel, modifiers: [.option]))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 160, y: 160),
                                        in: panel, modifiers: [.option]))
        let centeredDraft = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 160, y: 160),
                                   in: panel, modifiers: [.option]))
        guard case .styledRectangleWithRadius(let square, _, _, _) = canvas.annotations[0]
        else { preconditionFailure("Option 应固定按下点沿拖动方向绘制矩形") }
        let centeredSaved = pixels(try canvas.renderedImage())
        check(square == CGRect(x: 120, y: 130, width: 40, height: 40) &&
              centeredDraft == centeredSaved,
              "Option 正方形应朝鼠标方向延伸，实时预览和保存结果一致")

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 320, y: 130), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 370, y: 150),
                                        in: panel, modifiers: [.option]))
        let optionDraft = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 370, y: 150), in: panel))
        let normalDraft = pixels(try canvas.arrowDraftImageForSmoke())
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 370, y: 150), in: panel))
        guard case .styledRectangleWithRadius(let ordinary, _, _, _) = canvas.annotations[1]
        else { preconditionFailure("松开 Option 后应恢复普通矩形") }
        let ordinarySaved = pixels(try canvas.renderedImage())
        check(ordinary == CGRect(x: 320, y: 130, width: 50, height: 20) &&
              optionDraft != normalDraft && normalDraft == ordinarySaved,
              "拖动途中按下及松开 Option 应即时切换等宽高绘制，并与保存结果一致")

        canvas.tool = .ellipse
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 20, y: 270),
                                     in: panel, modifiers: [.option]))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 100, y: 190),
                                        in: panel, modifiers: [.option]))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 100, y: 190),
                                   in: panel, modifiers: [.option]))
        guard case .styledEllipse(let circle, _, _) = canvas.annotations[2]
        else { preconditionFailure("Option 应固定按下点沿鼠标方向绘制正圆") }
        check(circle == CGRect(x: 20, y: 190, width: 80, height: 80),
              "靠近截图边缘时，正圆应沿拖动方向延伸并限制在图片范围内")
        panel.contentView = nil
    }

    @MainActor static func verifySelectionAfterAnnotation() throws {
        func image(width: Int, height: Int) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        let canvas = ScreenshotAnnotationCanvas(image: image(width: 500, height: 400),
                                                 contentInset: 0)
        canvas.strokePixelsPerPoint = 2
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        panel.contentView = host
        canvas.frame = CGRect(x: 50, y: 50, width: 250, height: 200)
        host.addSubview(canvas)
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 100), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 180, y: 160), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 180, y: 160), in: panel))
        guard case .styledRectangleWithRadius(let original, _, _, _) = canvas.annotations.first else {
            preconditionFailure("选区测试应先产生矩形标注")
        }
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 300, y: 250), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 340, y: 280), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 340, y: 280), in: panel))
        check(canvas.frame == CGRect(x: 50, y: 50, width: 290, height: 230),
              "已有标注后，右上锚点仍应调整截图范围")
        canvas.replaceImage(image(width: 580, height: 460),
                            from: CGRect(x: 50, y: 50, width: 250, height: 200),
                            to: canvas.frame, movingSelection: false)
        guard case .styledRectangleWithRadius(let resized, _, _, _) = canvas.annotations.first else {
            preconditionFailure("改变选区后应保留矢量标注")
        }
        check(resized == original, "扩大选区时已有标注不应被拉伸")
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 50, y: 110), in: panel))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 80, y: 140), in: panel))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 80, y: 140), in: panel))
        check(canvas.frame.origin == CGPoint(x: 80, y: 80),
              "已有标注后仍能拖动选区边框")
        canvas.replaceImage(image(width: 580, height: 460),
                            from: CGRect(x: 50, y: 50, width: 290, height: 230),
                            to: canvas.frame, movingSelection: true)
        guard case .styledRectangleWithRadius(let moved, _, _, _) = canvas.annotations.first else {
            preconditionFailure("移动选区后应保留矢量标注")
        }
        check(moved == original, "移动选区时标注应与选区整体移动")
        canvas.replaceImage(image(width: 620, height: 500),
                            from: CGRect(x: 80, y: 80, width: 290, height: 230),
                            to: CGRect(x: 60, y: 60, width: 310, height: 250),
                            movingSelection: false)
        guard case .styledRectangleWithRadius(let expanded, _, _, _) = canvas.annotations.first else {
            preconditionFailure("左下方扩大选区后应保留矢量标注")
        }
        check(expanded == original.offsetBy(dx: 40, dy: 40),
              "从左下扩大选区时，已有标注应对齐原屏幕内容且不缩放")
        panel.contentView = nil
    }

    static func verifyThinArrowHeads() {
        for style in [ScreenshotArrowStyle.rounded, .sharp] {
            let full = ScreenshotArrowGeometry.path(from: .zero,
                to: CGPoint(x: 240, y: 0), style: style, shaftWidth: 6)
            let thin = ScreenshotArrowGeometry.path(from: .zero,
                to: CGPoint(x: 240, y: 0), style: style, shaftWidth: 6,
                thicknessScale: 0.2)
            check(thin.boundingBoxOfPath.height < full.boundingBoxOfPath.height * 0.4,
                  "箭杆调细时，实心箭头也必须明显变小")
        }
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 240, y: 0)
        let control = CGPoint(x: 120, y: 70)
        let full = ScreenshotBezierArrowGeometry.path(from: start, control: control,
            to: end, minimumWidth: 6)
        let thin = ScreenshotBezierArrowGeometry.path(from: start, control: control,
            to: end, minimumWidth: 6, thicknessScale: 0.2)
        let fullVertices = vertices(full)
        let thinVertices = vertices(thin)
        let fullTip = fullVertices.firstIndex(of: end)!
        let thinTip = thinVertices.firstIndex(of: end)!
        let fullWing = hypot(fullVertices[fullTip - 1].x - end.x,
                             fullVertices[fullTip - 1].y - end.y)
        let thinWing = hypot(thinVertices[thinTip - 1].x - end.x,
                             thinVertices[thinTip - 1].y - end.y)
        check(thinWing < fullWing * 0.4,
              "贝塞尔箭杆调细时，头部尺寸也应同步缩小")
    }

    static func vertices(_ path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = []
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                result.append(element.pointee.points[0])
            }
        }
        return result
    }

    static func verifyBezierHeadGeometry() {
        let start = CGPoint(x: 35, y: 40)
        let end = CGPoint(x: 350, y: 190)
        let controls = [
            ScreenshotBezierArrowGeometry.defaultControl(from: start, to: end),
            CGPoint(x: 370, y: 295), CGPoint(x: 460, y: 285),
            CGPoint(x: 90, y: 270), CGPoint(x: 270, y: 15),
            CGPoint(x: 440, y: 70), start, end,
            CGPoint(x: end.x + 0.00001, y: end.y - 0.00001)
        ]
        var referenceSize: CGSize?
        for control in controls {
            let path = ScreenshotBezierArrowGeometry.path(
                from: start, control: control, to: end, minimumWidth: 6)
            let points = vertices(path)
            precondition(points.allSatisfy { $0.x.isFinite && $0.y.isFinite },
                         "控制点位于起点或终点附近时也不能生成无效轮廓")
            let index = points.firstIndex(of: end)!
            let left = points[index - 1]
            let right = points[index + 1]
            let base = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
            let leftEdge = hypot(left.x - end.x, left.y - end.y)
            let rightEdge = hypot(right.x - end.x, right.y - end.y)
            precondition(abs(leftEdge - rightEdge) < 0.00001,
                         "拖动中间手柄后，实际箭头轮廓的两条斜边必须等长，不能压扁或拉歪")
            let headLength = hypot(end.x - base.x, end.y - base.y)
            let headWidth = hypot(left.x - right.x, left.y - right.y)
            precondition(headLength > 0 && headWidth > 0,
                         "箭头头部应始终保持可见的三角形")
            if let referenceSize {
                precondition(abs(headLength - referenceSize.width) < 0.00001 &&
                             abs(headWidth - referenceSize.height) < 0.00001,
                             "起终点不变时，调整曲率只能改变头部朝向，不能改变头部比例")
            } else { referenceSize = CGSize(width: headLength, height: headWidth) }
            let upperNeck = points[index - 2]
            let lowerNeck = points[index + 2]
            precondition(hypot((upperNeck.x + lowerNeck.x) / 2 - base.x,
                               (upperNeck.y + lowerNeck.y) / 2 - base.y) < 0.00001,
                         "箭身必须接在头部底边的中央，不能斜接到一侧")
        }
        precondition(ScreenshotBezierArrowGeometry.path(from: start, control: end,
            to: start, minimumWidth: 6).isEmpty,
            "重合的起终点不应生成异常曲线")
    }

    static func pixels(_ image: CGImage) -> Data {
        image.dataProvider!.data! as Data
    }

    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
}
