import AppKit

@main
struct PinnedImageGeometrySmoke {
    @MainActor static func main() {
        let pointer = NSPoint(x: 200, y: 340)
        let initial = NSRect(x: 100, y: 100, width: 300, height: 552)
        let inset = PinnedImageGeometry.shadowInset
        let initialX = (pointer.x - initial.minX - inset) / (initial.width - inset * 2)
        let initialY = (pointer.y - initial.minY - inset) / (initial.height - inset * 2)

        var frame = initial
        for _ in 0..<30 {
            frame = PinnedImageGeometry.magnifiedFrame(
                frame, imageRatio: 0.5, pointer: pointer, delta: 0.2)
        }
        precondition(frame.height > 2_000, "贴图应能放大到超过屏幕高度")
        precondition(abs((frame.width - inset * 2) / (frame.height - inset * 2) - 0.5) < 0.0001,
                     "放大后应保持图片比例")
        precondition(abs((pointer.x - frame.minX - inset) / (frame.width - inset * 2) - initialX) < 0.0001,
                     "放大时不应让手指位置下的内容横向跳动")
        precondition(abs((pointer.y - frame.minY - inset) / (frame.height - inset * 2) - initialY) < 0.0001,
                     "放大时不应让手指位置下的内容纵向跳动")

        let reduced = PinnedImageGeometry.magnifiedFrame(
            frame, imageRatio: 0.5, pointer: pointer, delta: -0.2)
        precondition(reduced.width < frame.width, "到达上限后仍应可以缩小")

        var small = initial
        for _ in 0..<40 {
            small = PinnedImageGeometry.magnifiedFrame(
                small, imageRatio: 0.5, pointer: pointer, delta: -0.2)
        }
        precondition(abs(small.width - 88) < 0.001,
                     "最小图片内容宽应为 40 点，另有两侧各 24 点的阴影留白")

        let visibleScreen = NSRect(x: 0, y: 0, width: 400, height: 300)
        let narrowImage = NSRect(x: 0, y: 60, width: 88, height: 220)
        let hint = PinnedImageGeometry.gestureHintFrame(
            over: narrowImage, visibleFrame: visibleScreen,
            size: NSSize(width: 294, height: 88)
        )
        precondition(hint.minX >= 8 && hint.maxX <= visibleScreen.maxX - 8 &&
                     hint.minY >= 8 && hint.maxY <= visibleScreen.maxY - 8,
                     "窄图上的操作提示不得跑出屏幕")
        precondition(hint.intersects(narrowImage), "操作提示应覆盖在钉住的图片上")
        checkToolbarPlacement()
        checkNativeWindow()
    }

    private static func checkToolbarPlacement() {
        let screen = NSRect(x: -1200, y: 200, width: 1_200, height: 800)
        let size = NSSize(width: 118, height: 34)
        func check(_ image: NSRect, edge: NSRectEdge) {
            let placement = PinnedImageGeometry.toolbarPlacement(over: image, in: screen, size: size)
            precondition(placement?.outwardEdge == edge)
            precondition(placement.map { screen.contains($0.frame) && !$0.frame.intersects(image) } == true,
                         "工具条必须留在屏幕内，且不能盖住图片")
        }
        check(NSRect(x: -650, y: 470, width: 500, height: 52), edge: .maxY)
        check(NSRect(x: -110, y: 935, width: 80, height: 80), edge: .minY)
        check(NSRect(x: -1_200, y: 200, width: 520, height: 800), edge: .maxX)
        check(NSRect(x: -450, y: 200, width: 450, height: 800), edge: .minX)
        precondition(PinnedImageGeometry.toolbarPlacement(over: screen, in: screen, size: size) == nil,
                     "贴图填满屏幕时，应通过右键菜单操作，工具条不覆盖图片")
    }

    @MainActor private static func checkNativeWindow() {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else {
            print("Pinned image geometry smoke passed; native screen test skipped (no display)")
            return
        }
        // The bug is specific to an ordered AppKit panel. Keep the synthetic
        // window transparent and out of mouse dispatch while testing it.
        let size = NSSize(width: 600, height: 60)
        let image = NSImage(size: size, flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            return true
        }
        let frame = NSRect(x: screen.frame.minX + 80, y: screen.frame.midY,
                           width: size.width + 48, height: size.height + 48)
        let record = PinnedImageRecord(id: UUID(), sourceEntryID: UUID(), fileName: "synthetic",
                                       title: "Synthetic pin", allSpaces: true)
        var savedFrame: NSRect?
        var savedOpacity: Double?
        let pin = PinnedImageWindow(record: record, image: image, frame: frame,
            pasteFocusHandoff: PasteFocusHandoff(), onClose: {}, onCopyImage: {},
            onDismissShelf: { false }, onFrameChanged: { savedFrame = $0 },
            onOpacityChanged: { savedOpacity = $0 }, onHover: {}, onHoverEnded: {}, onImageClicked: {})
        pin.panel.alphaValue = 0
        pin.panel.ignoresMouseEvents = true
        pin.show()
        defer { pin.dismiss() }
        let inset = PinnedImageGeometry.shadowInset
        pin.panel.setFrameOrigin(NSPoint(x: frame.minX, y: screen.frame.maxY - size.height - inset))
        let atTop = PinnedImageGeometry.imageFrame(in: pin.panel.frame, imageRatio: 10)
        precondition(abs(atTop.maxY - screen.frame.maxY) < 1,
                     "系统不能再把图片顶部挡在菜单栏下方")
        pin.panel.setFrameOrigin(NSPoint(x: frame.minX, y: screen.frame.maxY - 2))
        let topSlice = PinnedImageGeometry.imageFrame(in: pin.panel.frame, imageRatio: 10).intersection(screen.frame)
        precondition(!topSlice.isEmpty && topSlice.height >= 24,
                     "过度上拖后还应保留可抓取的图片区域")

        pin.panel.setFrame(frame, display: false)
        let canvas = pin.panel.contentView as! PinnedImageCanvas
        canvas.checkControlsForSmoke()
        precondition(savedFrame == pin.panel.frame && savedOpacity == 0.37,
                     "滑杆调整应通过原有保存入口记录当前大小和透明度")
        print("Pinned image geometry smoke passed: native top-edge movement, reachable image, outside toolbar and live sliders")
    }
}

private extension PinnedImageCanvas {
    func checkControlsForSmoke() {
        guard let window else { preconditionFailure("Missing pinned window") }
        showToolbar()
        guard let toolbarPanel, toolbarPanel.isVisible else { preconditionFailure("Toolbar did not appear") }
        let toolbarFrame = toolbarPanel.frame
        precondition(toolbarFrame.minY > imageOnScreen(in: window).maxY && toolButtons.count == 4,
                     "默认在图上方显示四个操作按钮")
        zoomButton.performClick(nil)
        guard let zoom = adjustmentControls, zoom.slider.isContinuous, zoom.popover.isShown else {
            preconditionFailure("Zoom button did not open a continuous native slider")
        }
        zoom.popover.contentViewController?.view.window?.alphaValue = 0
        for width in [310.0, 890.0] {
            zoom.slider.doubleValue = log(width)
            _ = zoom.slider.sendAction(zoom.slider.action, to: zoom.slider.target)
            precondition(abs(imageRect.width - width) < 1, "拖动缩放滑杆后应立即成比例调整")
            precondition(toolbarPanel.frame == toolbarFrame && !toolbarFrame.intersects(imageOnScreen(in: window)),
                         "拖动滑杆时工具条应保持稳定，且不能挡住贴图")
        }
        opacityButton.performClick(nil)
        guard let opacity = adjustmentControls, opacity.slider.isContinuous, opacity.popover.isShown else {
            preconditionFailure("Opacity button did not switch to a continuous native slider")
        }
        opacity.popover.contentViewController?.view.window?.alphaValue = 0
        opacity.slider.doubleValue = 0.37
        _ = opacity.slider.sendAction(opacity.slider.action, to: opacity.slider.target)
        precondition(abs(imageOpacity - 0.37) < 0.001 && abs(imageRect.width - 890) < 1,
                     "透明度滑杆应实时调整图片透明度")
    }
}
