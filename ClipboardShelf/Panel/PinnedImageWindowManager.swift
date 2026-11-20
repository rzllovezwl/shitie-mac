import AppKit
import Carbon
import ImageIO
import QuartzCore
import SwiftUI

enum PinnedImageGeometry {
    static let shadowInset = PinnedImageRecord.shadowInset
    // A pin can grow beyond the desktop. Keep the backing surface bounded so
    // repeated gestures cannot allocate an unmanageably large window.
    static let maximumContentExtent: CGFloat = 4_096

    static func gestureHintFrame(over imageWindowFrame: NSRect,
                                 visibleFrame: NSRect, size: NSSize) -> NSRect {
        let image = imageWindowFrame.insetBy(dx: shadowInset, dy: shadowInset)
        let visibleImage = image.intersection(visibleFrame)
        let anchor = visibleImage.isNull ? image : visibleImage
        let safeFrame = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(size.width, safeFrame.width)
        let height = min(size.height, safeFrame.height)
        let x = min(max(anchor.midX - width / 2, safeFrame.minX), safeFrame.maxX - width)
        let y = min(max(anchor.midY - height / 2, safeFrame.minY), safeFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func magnifiedFrame(_ frame: NSRect, imageRatio: CGFloat,
                               pointer: NSPoint, delta: CGFloat) -> NSRect {
        guard imageRatio.isFinite, imageRatio > 0,
              delta.isFinite, delta != 0 else { return frame }
        let width = imageFrame(in: frame, imageRatio: imageRatio).width
        return resizedFrame(frame, imageRatio: imageRatio, anchor: pointer,
                            contentWidth: width * exp(min(0.5, max(-0.5, delta))))
    }

    static func contentWidthRange(imageRatio: CGFloat) -> ClosedRange<CGFloat> {
        let maximumWidth = maximumContentExtent * min(1, imageRatio)
        return min(40, maximumWidth / 4)...maximumWidth
    }

    static func imageFrame(in frame: NSRect, imageRatio: CGFloat) -> NSRect {
        let available = frame.insetBy(dx: shadowInset, dy: shadowInset)
        guard imageRatio.isFinite, imageRatio > 0,
              available.width > 0, available.height > 0 else { return .zero }
        let width = min(available.width, available.height * imageRatio)
        let height = width / imageRatio
        return NSRect(x: available.midX - width / 2, y: available.midY - height / 2,
                      width: width, height: height)
    }

    static func resizedFrame(_ frame: NSRect, imageRatio: CGFloat, anchor: NSPoint,
                             contentWidth: CGFloat) -> NSRect {
        let oldImage = imageFrame(in: frame, imageRatio: imageRatio)
        guard oldImage.width > 0, oldImage.height > 0, contentWidth.isFinite else { return frame }
        let limits = contentWidthRange(imageRatio: imageRatio)
        let width = min(limits.upperBound, max(limits.lowerBound, contentWidth))
        let height = width / imageRatio
        let relativeX = min(1, max(0, (anchor.x - oldImage.minX) / oldImage.width))
        let relativeY = min(1, max(0, (anchor.y - oldImage.minY) / oldImage.height))
        return NSRect(x: anchor.x - relativeX * width, y: anchor.y - relativeY * height,
                      width: width, height: height).insetBy(dx: -shadowInset, dy: -shadowInset)
    }

    static func reachableFrame(_ frame: NSRect, imageRatio: CGFloat, screens: [NSRect]) -> NSRect {
        let image = imageFrame(in: frame, imageRatio: imageRatio)
        guard image.width > 0, image.height > 0 else { return frame }
        // Let the image reach the physical screen edges. Keep enough of it
        // visible to grab again, even if its window spans several displays.
        var nearest: NSPoint?
        var shortestDistance = CGFloat.infinity
        for screen in screens where !screen.isEmpty {
            let width = min(32, min(image.width, screen.width))
            let height = min(24, min(image.height, screen.height))
            let x = min(max(image.minX, screen.minX + width - image.width), screen.maxX - width)
            let y = min(max(image.minY, screen.minY + height - image.height), screen.maxY - height)
            let offset = NSPoint(x: x - image.minX, y: y - image.minY)
            let distance = hypot(offset.x, offset.y)
            if distance == 0 { return frame }
            if distance < shortestDistance {
                nearest = offset
                shortestDistance = distance
            }
        }
        guard let nearest else { return frame }
        return frame.offsetBy(dx: nearest.x, dy: nearest.y)
    }

    struct ToolbarPlacement {
        let frame: NSRect
        let outwardEdge: NSRectEdge
    }

    static func toolbarPlacement(over image: NSRect, in visibleFrame: NSRect,
                                 size: NSSize) -> ToolbarPlacement? {
        let screen = visibleFrame.insetBy(dx: 4, dy: 4)
        guard screen.width >= size.width, screen.height >= size.height else { return nil }
        let gap: CGFloat = 6
        let x = min(max(image.minX, screen.minX), screen.maxX - size.width)
        let y = min(max(image.maxY - size.height, screen.minY), screen.maxY - size.height)
        let above = max(screen.minY, image.maxY + gap)
        if above + size.height <= screen.maxY {
            return ToolbarPlacement(frame: NSRect(origin: NSPoint(x: x, y: above), size: size),
                                    outwardEdge: .maxY)
        }
        let below = min(screen.maxY, image.minY - gap) - size.height
        if below >= screen.minY {
            return ToolbarPlacement(frame: NSRect(origin: NSPoint(x: x, y: below), size: size),
                                    outwardEdge: .minY)
        }
        let right = max(screen.minX, image.maxX + gap)
        if right + size.width <= screen.maxX {
            return ToolbarPlacement(frame: NSRect(origin: NSPoint(x: right, y: y), size: size),
                                    outwardEdge: .maxX)
        }
        let left = min(screen.maxX, image.minX - gap) - size.width
        if left >= screen.minX {
            return ToolbarPlacement(frame: NSRect(origin: NSPoint(x: left, y: y), size: size),
                                    outwardEdge: .minX)
        }
        return nil
    }
}

private final class PinnedImagePanel: NSPanel {
    var pasteFocusHandoff: PasteFocusHandoff?
    var imageRatio: CGFloat?

    // The image needs to become key for AppKit to deliver trackpad gestures.
    // The close button opts out below so dismissing a pin does not take focus.
    override var canBecomeKey: Bool { pasteFocusHandoff?.allowsPinnedImageKey ?? true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let imageRatio else { return frameRect }
        // The outer frame includes transparent shadow insets. Constrain the
        // actual image against the full displays, including above visibleFrame.
        return PinnedImageGeometry.reachableFrame(frameRect, imageRatio: imageRatio,
                                                  screens: NSScreen.screens.map(\.frame))
    }
}

private final class PinnedImageAccessoryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PinnedGestureHintView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.cyan)
                Text("已钉在桌面")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("双指捏合缩放 · 上下滑动调透明度\n双击图片取消钉住")
                .font(.system(size: 12))
                .lineSpacing(3)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        }
    }
}

private final class PinnedImageToolButton: NSButton {
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PinnedImageToolbar: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

/// Displays a pinned image and its floating controls in a transparent panel.
private final class PinnedImageCanvas: NSView, NSPopoverDelegate {
    static let shadowInset = PinnedImageGeometry.shadowInset

    let image: NSImage
    var imageOpacity: CGFloat {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.opacity = Float(imageOpacity)
            CATransaction.commit()
            // AppKit's window shadow stays visually strong as the image layer
            // fades. At reduced opacity it reads as a dark rectangular frame.
            // Keep the native shadow for an opaque pin and remove it for a
            // translucent pin instead of leaving a mismatched border.
            if let window {
                let shouldShowShadow = imageOpacity >= 0.99
                if window.hasShadow != shouldShowShadow {
                    window.hasShadow = shouldShowShadow
                } else if shouldShowShadow {
                    window.invalidateShadow()
                }
            }
            updateAdjustmentControls()
        }
    }
    var onUnpin: (() -> Void)?
    var onCopyImage: (() -> Void)?
    var onDismissShelf: (() -> Bool)?
    var onMagnify: ((CGFloat) -> Void)?
    var onOpacityChanged: ((CGFloat) -> Void)?
    var onRequestGestureFocus: (() -> Void)?
    var onHoverEnded: (() -> Void)?
    var onImageClicked: (() -> Void)?
    var onZoomChanged: ((CGFloat, NSPoint) -> Void)?
    var onResetZoom: (() -> Void)?

    private let toolbar = PinnedImageToolbar(frame: .zero)
    private let closeButton = PinnedImageToolButton(frame: .zero)
    private let zoomButton = PinnedImageToolButton(frame: .zero)
    private let resetZoomButton = PinnedImageToolButton(frame: .zero)
    private let opacityButton = PinnedImageToolButton(frame: .zero)
    private var toolbarPanel: PinnedImageAccessoryPanel?
    private var toolbarPlacement: PinnedImageGeometry.ToolbarPlacement?
    private var toolbarHideTask: Task<Void, Never>?
    private var isHoveringImage = false
    private var contextClickOnScreen: NSPoint?
    private let imageLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var dragStart: (mouse: NSPoint, frame: NSRect)?
    private enum Adjustment: Equatable {
        case zoom, opacity
        var title: String { self == .zoom ? "缩放" : "透明度" }
    }
    private struct AdjustmentControls {
        let kind: Adjustment
        let popover: NSPopover
        let label: NSTextField
        let slider: NSSlider
        let zoomPivot: NSPoint?
        let imageAnchorOnScreen: NSRect?
    }
    private var adjustmentControls: AdjustmentControls?

    init(image: NSImage, opacity: CGFloat) {
        self.image = image
        imageOpacity = opacity
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        imageLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        imageLayer.contentsGravity = .resize
        imageLayer.opacity = Float(opacity)
        layer?.addSublayer(imageLayer)
        configureToolbar()
        setAccessibilityLabel("钉在桌面的图片：拖动移动，捏合缩放，双指上下滑动调整透明度，双击取消钉住")
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let rect = imageRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = rect
        CATransaction.commit()
        if toolbarPanel?.isVisible == true { showToolbar() }
        updateAdjustmentControls()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }
    override func mouseExited(with event: NSEvent) {
        isHoveringImage = false
        scheduleToolbarHide()
    }

    private func updateHover(with event: NSEvent) {
        isHoveringImage = imageRect.contains(convert(event.locationInWindow, from: nil))
        if isHoveringImage, dragStart == nil {
            toolbarHideTask?.cancel()
            if adjustmentControls?.popover.isShown != true { onRequestGestureFocus?() }
            showToolbar()
        } else {
            scheduleToolbarHide()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let window, containsImage(convert(event.locationInWindow, from: nil)) else {
            return super.menu(for: event)
        }
        contextClickOnScreen = window.convertPoint(toScreen: event.locationInWindow)
        let menu = NSMenu()
        if onCopyImage != nil {
            let copy = menu.addItem(withTitle: "复制图片", action: #selector(copyImageClicked), keyEquivalent: "")
            copy.target = self
            menu.addItem(.separator())
        }
        // These remain available when an oversized pin leaves no space next
        // to the image for the toolbar.
        for (title, action) in [("调整缩放…", #selector(zoomClicked(_:))),
                                ("原始大小（100%）", #selector(resetZoomClicked)),
                                ("调整透明度…", #selector(opacityClicked(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    @objc private func copyImageClicked() { onCopyImage?() }

    override func mouseDown(with event: NSEvent) {
        // Capture the original press before changing focus or saving z-order.
        // Those operations can finish after the pointer has started to move.
        if let window, event.clickCount < 2 {
            dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame)
        } else {
            dragStart = nil
        }
        _ = onDismissShelf?()
        if event.clickCount >= 2 {
            onUnpin?()
            return
        }
        onImageClicked?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        dismissAdjustment()
        toolbarPanel?.orderOut(nil)
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: dragStart.frame.minX + mouse.x - dragStart.mouse.x,
            y: dragStart.frame.minY + mouse.y - dragStart.mouse.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        updateHover(with: event)
    }

    override func magnify(with event: NSEvent) {
#if DEBUG
        ImageGestureTrace.record("pin canvas magnify delta=\(event.magnification) window=\(window?.windowNumber ?? -1)")
#endif
        onMagnify?(event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }
        let next = min(1, max(CGFloat(PinnedImageRecord.minimumOpacity),
                              imageOpacity + event.scrollingDeltaY * 0.005))
        guard next != imageOpacity else { return }
        imageOpacity = next
        onOpacityChanged?(next)
    }

    private var toolButtons: [PinnedImageToolButton] {
        [closeButton, zoomButton, resetZoomButton, opacityButton]
    }

    private func configureToolbar() {
        toolbar.appearance = NSAppearance(named: .darkAqua)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0.09, alpha: 0.60).cgColor
        toolbar.layer?.cornerRadius = 10
        toolbar.layer?.masksToBounds = true
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        toolbar.onHoverChanged = { [weak self] hovering in
            if hovering { self?.toolbarHideTask?.cancel() }
            else { self?.scheduleToolbarHide() }
        }

        configure(closeButton, symbol: "xmark", help: "取消钉住",
                  action: #selector(closeClicked))
        configure(zoomButton, symbol: "magnifyingglass", help: "调整缩放",
                  action: #selector(zoomClicked(_:)))
        configure(resetZoomButton, symbol: nil, help: "原始大小（100%）",
                  action: #selector(resetZoomClicked))
        resetZoomButton.title = "1:1"
        resetZoomButton.imagePosition = .noImage
        resetZoomButton.font = .systemFont(ofSize: 11, weight: .semibold)
        configure(opacityButton, symbol: "circle.lefthalf.filled", help: "调整透明度",
                  action: #selector(opacityClicked(_:)))
        let side: CGFloat = 26
        let gap: CGFloat = 2
        let padding: CGFloat = 4
        let width = (side + gap) * CGFloat(toolButtons.count) - gap + padding * 2
        toolbar.frame.size = NSSize(width: width, height: side + padding * 2)
        for (index, button) in toolButtons.enumerated() {
            button.frame = NSRect(x: padding + CGFloat(index) * (side + gap),
                                  y: padding, width: side, height: side)
            toolbar.addSubview(button)
        }
    }

    private func configure(_ button: PinnedImageToolButton, symbol: String?,
                           help: String, action: Selector) {
        button.title = ""
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: help) }
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .white
        button.focusRingType = .none
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.target = self
        button.action = action
    }

    private func showToolbar() {
        guard dragStart == nil, let window, window.isVisible else { return }
        // During slider tracking the image grows away from the toolbar. Keep
        // the control at its original screen position under the pointer.
        if let controls = adjustmentControls, controls.imageAnchorOnScreen == nil,
           controls.popover.isShown { return }
        guard let screen = window.screen,
              let placement = PinnedImageGeometry.toolbarPlacement(
                over: imageOnScreen(in: window), in: screen.visibleFrame, size: toolbar.bounds.size
              ) else {
            toolbarPanel?.orderOut(nil)
            toolbarPlacement = nil
            return
        }
        toolbarPlacement = placement
        if let toolbarPanel {
            if toolbarPanel.frame != placement.frame { toolbarPanel.setFrame(placement.frame, display: true) }
            if !toolbarPanel.isVisible { toolbarPanel.order(.above, relativeTo: window.windowNumber) }
        } else {
            let panel = PinnedImageAccessoryPanel(contentRect: placement.frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = window.level
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.alphaValue = window.alphaValue
            panel.collectionBehavior = window.collectionBehavior
            panel.contentView = toolbar
            toolbarPanel = panel
            panel.order(.above, relativeTo: window.windowNumber)
        }
    }

    private func scheduleToolbarHide() {
        toolbarHideTask?.cancel()
        toolbarHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(230))
            guard let self, !Task.isCancelled, !self.isHoveringImage,
                  self.adjustmentControls?.popover.isShown != true else { return }
            let pointer = NSEvent.mouseLocation
            if let panel = self.toolbarPanel, panel.isVisible, panel.frame.contains(pointer) { return }
            self.toolbarPanel?.orderOut(nil)
            self.onHoverEnded?()
        }
    }

    @objc private func zoomClicked(_ sender: Any?) {
        showAdjustment(.zoom, button: sender as? NSButton)
    }

    @objc private func resetZoomClicked() {
        _ = onDismissShelf?()
        dismissAdjustment()
        onResetZoom?()
    }

    @objc private func opacityClicked(_ sender: Any?) {
        showAdjustment(.opacity, button: sender as? NSButton)
    }

    private func showAdjustment(_ kind: Adjustment, button: NSButton?) {
        _ = onDismissShelf?()
        let togglesOff = adjustmentControls?.kind == kind && adjustmentControls?.popover.isShown == true
        adjustmentControls?.popover.close()
        guard !togglesOff, let window, window.isVisible else { return }
        toolbarHideTask?.cancel()
        let image = imageOnScreen(in: window)
        let imageAnchor: NSRect?
        let pivot: NSPoint
        if button != nil, let placement = toolbarPlacement {
            imageAnchor = nil
            let intersection = image.intersection(window.screen?.frame ?? image)
            let visible = intersection.isEmpty ? image : intersection
            switch placement.outwardEdge {
            case .maxY: pivot = NSPoint(x: visible.minX, y: image.maxY)
            case .minY: pivot = NSPoint(x: visible.minX, y: image.minY)
            case .maxX: pivot = NSPoint(x: image.maxX, y: visible.maxY)
            case .minX: pivot = NSPoint(x: image.minX, y: visible.maxY)
            @unknown default: pivot = NSPoint(x: image.midX, y: image.midY)
            }
        } else {
            pivot = contextClickOnScreen ?? NSPoint(x: image.midX, y: image.midY)
            imageAnchor = NSRect(origin: pivot, size: NSSize(width: 1, height: 1))
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 204, height: 64))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 12, y: 38, width: 180, height: 18)
        content.addSubview(label)
        let slider = NSSlider(frame: .zero)
        slider.target = self
        slider.action = #selector(adjustmentSliderChanged(_:))
        slider.isContinuous = true
        slider.setAccessibilityLabel(kind.title)
        if kind == .zoom {
            // Leave usable slider space at small sizes even when a pin can
            // grow to several times the desktop width.
            let limits = PinnedImageGeometry.contentWidthRange(imageRatio: imageRatio)
            slider.minValue = log(Double(limits.lowerBound))
            slider.maxValue = log(Double(limits.upperBound))
        } else {
            slider.minValue = PinnedImageRecord.minimumOpacity
            slider.maxValue = 1
        }
        slider.frame = NSRect(x: 12, y: 10, width: 180, height: 22)
        content.addSubview(slider)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = toolbar.appearance
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        popover.delegate = self
        adjustmentControls = AdjustmentControls(kind: kind, popover: popover,
            label: label, slider: slider, zoomPivot: kind == .zoom ? pivot : nil,
            imageAnchorOnScreen: imageAnchor)
        updateAdjustmentControls()
        if let button, let placement = toolbarPlacement {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: placement.outwardEdge)
        } else if let imageAnchor {
            popover.show(relativeTo: convert(window.convertFromScreen(imageAnchor), from: nil),
                         of: self, preferredEdge: .maxY)
        }
    }

    private func updateAdjustmentControls() {
        guard let controls = adjustmentControls else { return }
        let percent: String
        switch controls.kind {
        case .zoom:
            let width = imageRect.width
            guard width > 0 else { return }
            controls.slider.doubleValue = log(Double(width))
            percent = "\(max(1, Int((width / actualSizeWidth * 100).rounded())))%"
            if let window, let anchor = controls.imageAnchorOnScreen, controls.popover.isShown {
                let rect = convert(window.convertFromScreen(anchor), from: nil)
                if controls.popover.positioningRect != rect { controls.popover.positioningRect = rect }
            }
        case .opacity:
            controls.slider.doubleValue = Double(imageOpacity)
            percent = "\(Int((imageOpacity * 100).rounded()))%"
        }
        controls.label.stringValue = "\(controls.kind.title) \(percent)"
        controls.slider.setAccessibilityValueDescription(percent)
    }

    @objc private func adjustmentSliderChanged(_ sender: NSSlider) {
        guard let controls = adjustmentControls, controls.slider === sender else { return }
        switch controls.kind {
        case .zoom:
            guard let pivot = controls.zoomPivot else { return }
            onZoomChanged?(CGFloat(exp(sender.doubleValue)), pivot)
            updateAdjustmentControls()
        case .opacity:
            let value = CGFloat(sender.doubleValue)
            imageOpacity = value
            onOpacityChanged?(value)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === adjustmentControls?.popover else { return }
        adjustmentControls = nil
        if isHoveringImage { showToolbar() }
        scheduleToolbarHide()
    }

    func dismissAdjustment() { adjustmentControls?.popover.close() }

    func dismissControls() {
        isHoveringImage = false
        dismissAdjustment()
        toolbarHideTask?.cancel()
        toolbarPanel?.close()
        toolbarPanel = nil
        toolbarPlacement = nil
    }

    func raiseToolbarIfVisible() {
        guard let window, let toolbarPanel, toolbarPanel.isVisible else { return }
        toolbarPanel.order(.above, relativeTo: window.windowNumber)
    }

    var imageRatio: CGFloat { image.size.width / image.size.height }

    var actualSizeWidth: CGFloat { image.size.width / (window?.backingScaleFactor ?? 1) }

    private var imageRect: NSRect {
        PinnedImageGeometry.imageFrame(in: bounds, imageRatio: imageRatio)
    }

    private func imageOnScreen(in window: NSWindow) -> NSRect {
        window.convertToScreen(convert(imageRect, to: nil))
    }

    func containsImage(_ point: NSPoint) -> Bool { imageRect.contains(point) }

    @objc private func closeClicked() {
        _ = onDismissShelf?()
        onUnpin?()
    }
}

@MainActor
private final class PinnedImageWindow: NSObject, NSWindowDelegate {
    let panel: PinnedImagePanel
    private let canvas: PinnedImageCanvas
    private let onClose: () -> Void
    private let onDismissShelf: () -> Bool
    private let onFrameChanged: (NSRect) -> Void
    private var closeRequested = false
    private var lastFocusAttempt: TimeInterval = 0

    var imageOpacity: Double { Double(canvas.imageOpacity) }

    init(record: PinnedImageRecord, image: NSImage, frame: NSRect,
         pasteFocusHandoff: PasteFocusHandoff,
         onClose: @escaping () -> Void,
         onCopyImage: @escaping () -> Void,
         onDismissShelf: @escaping () -> Bool,
         onFrameChanged: @escaping (NSRect) -> Void,
         onOpacityChanged: @escaping (Double) -> Void,
         onHover: @escaping () -> Void,
         onHoverEnded: @escaping () -> Void,
         onImageClicked: @escaping () -> Void) {
        self.onClose = onClose
        self.onDismissShelf = onDismissShelf
        self.onFrameChanged = onFrameChanged
        canvas = PinnedImageCanvas(image: image, opacity: CGFloat(record.displayOpacity))
        panel = PinnedImagePanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        super.init()
        panel.pasteFocusHandoff = pasteFocusHandoff
        panel.imageRatio = canvas.imageRatio
        panel.title = record.title
        panel.becomesKeyOnlyIfNeeded = true
        // Full-screen apps sit above ordinary floating panels.
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = record.displayOpacity >= 0.99
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = Self.collectionBehavior(allSpaces: record.allSpaces)
        panel.contentView = canvas
        panel.delegate = self
        canvas.onUnpin = { [weak self] in self?.requestClose() }
        canvas.onCopyImage = onCopyImage
        canvas.onDismissShelf = { [weak self] in self?.onDismissShelf() ?? false }
        canvas.onMagnify = { [weak self] amount in self?.resize(byMagnification: amount) }
        canvas.onOpacityChanged = { value in onOpacityChanged(Double(value)) }
        canvas.onRequestGestureFocus = { [weak self] in
            onHover()
            self?.requestGestureFocus()
        }
        canvas.onHoverEnded = onHoverEnded
        canvas.onImageClicked = onImageClicked
        canvas.onZoomChanged = { [weak self] width, anchor in
            self?.resize(toContentWidth: width, anchor: anchor)
        }
        canvas.onResetZoom = { [weak self] in self?.resetZoom() }
    }

    func show() {
        panel.orderFrontRegardless()
        canvas.raiseToolbarIfVisible()
    }

    func dismiss() {
        canvas.dismissControls()
        panel.delegate = nil
        panel.close()
    }

    func containsImage(atScreenPoint point: NSPoint) -> Bool {
        guard panel.isVisible, panel.frame.contains(point) else { return false }
        let windowPoint = panel.convertPoint(fromScreen: point)
        return canvas.containsImage(canvas.convert(windowPoint, from: nil))
    }

    func magnify(by amount: CGFloat) { resize(byMagnification: amount) }

    private func requestGestureFocus() {
        guard panel.isVisible,
              panel.pasteFocusHandoff?.allowsPinnedImageHoverFocus(at: NSEvent.mouseLocation) != false else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ==
            NSRunningApplication.current.processIdentifier
        if frontmost && panel.isKeyWindow { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFocusAttempt >= 0.15 else { return }
        lastFocusAttempt = now
        if !frontmost {
            // A key nonactivating panel still does not receive magnify events
            // after another app takes the event stream. The pointer returning
            // to this image is an explicit request to interact with it.
            NSApp.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate()
        }
        panel.makeKeyAndOrderFront(nil)
        canvas.raiseToolbarIfVisible()
#if DEBUG
        ImageGestureTrace.record("pin focus requested frontmost=\(frontmost) key=\(panel.isKeyWindow) window=\(panel.windowNumber)")
#endif
    }

    private func resetZoom() {
        resize(toContentWidth: canvas.actualSizeWidth,
               anchor: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
    }

    private func resize(toContentWidth width: CGFloat, anchor: NSPoint) {
        let frame = PinnedImageGeometry.resizedFrame(panel.frame, imageRatio: canvas.imageRatio,
                                                    anchor: anchor, contentWidth: width)
        applyResizedFrame(frame)
    }

    private func requestClose() {
        guard !closeRequested else { return }
        closeRequested = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.closeRequested = false
            self.onClose()
        }
    }

    private func resize(byMagnification amount: CGFloat) {
        guard amount.isFinite, amount != 0 else { return }
        let frame = panel.frame
        let updated = PinnedImageGeometry.magnifiedFrame(
            frame, imageRatio: canvas.imageRatio, pointer: NSEvent.mouseLocation, delta: amount)
        guard updated != frame else { return }
        canvas.dismissAdjustment()
        applyResizedFrame(updated)
#if DEBUG
        ImageGestureTrace.record("pin resized delta=\(amount) oldWidth=\(frame.width) newWidth=\(panel.frame.width) window=\(panel.windowNumber)")
#endif
    }

    private func applyResizedFrame(_ frame: NSRect) {
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        onFrameChanged(panel.frame)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        canvas.needsLayout = true
        onFrameChanged(panel.frame)
    }

    func windowDidChangeScreen(_ notification: Notification) { canvas.needsLayout = true }
    func windowDidChangeBackingProperties(_ notification: Notification) { canvas.needsLayout = true }

    func windowDidResize(_ notification: Notification) {
        if panel.hasShadow { panel.invalidateShadow() }
        onFrameChanged(panel.frame)
    }

    private static func collectionBehavior(allSpaces: Bool) -> NSWindow.CollectionBehavior {
        let common: NSWindow.CollectionBehavior = [.canJoinAllApplications, .fullScreenAuxiliary]
        return allSpaces ? common.union([.canJoinAllSpaces, .stationary]) : common
    }
}

/// One borderless, nonactivating floating panel per pinned image.
@MainActor
final class PinnedImageWindowManager {
    private let store: PinnedImageStore
    private let pasteFocusHandoff: PasteFocusHandoff
    private let onChange: () -> Void
    private let onError: (String) -> Void
    private let onCopyImage: (PinnedImageRecord) -> Void
    private let onDismissShelf: () -> Bool
    private var windows: [UUID: PinnedImageWindow] = [:]
    private var frameTasks: [UUID: Task<Void, Never>] = [:]
    private var opacityTasks: [UUID: Task<Void, Never>] = [:]
    private var localMagnifyMonitor: Any?
    private var backgroundMagnifyMonitor: Any?
    private var localEscapeMonitor: Any?
    private var gestureHintPanel: PinnedImageAccessoryPanel?
    private var gestureHintForID: UUID?
    private var gestureHintDismissTask: Task<Void, Never>?
    private var hoveredID: UUID?

    var hasKeyWindow: Bool { windows.values.contains { $0.panel.isKeyWindow } }

    init(store: PinnedImageStore, pasteFocusHandoff: PasteFocusHandoff,
         onChange: @escaping () -> Void,
         onError: @escaping (String) -> Void,
         onCopyImage: @escaping (PinnedImageRecord) -> Void,
         onDismissShelf: @escaping () -> Bool) {
        self.store = store
        self.pasteFocusHandoff = pasteFocusHandoff
        self.onChange = onChange
        self.onError = onError
        self.onCopyImage = onCopyImage
        self.onDismissShelf = onDismissShelf
    }

    func restore() {
        for record in store.records {
            do { try show(record) }
            catch { onError("恢复贴图失败：\(error.localizedDescription)") }
        }
    }

    func showAll() {
        for record in store.records {
            do { try show(record) }
            catch { onError("显示贴图失败：\(error.localizedDescription)") }
        }
    }

    func show(_ record: PinnedImageRecord) throws {
        if let existing = windows[record.id] {
            existing.show()
            return
        }
        guard let url = store.imageURL(for: record),
              let image = displayImage(at: url) else { throw PinnedImageError.missingSnapshot }
        let frame = fittedFrame(record.frame?.rect, imageSize: image.size)
        let window = PinnedImageWindow(
            record: record, image: image, frame: frame,
            pasteFocusHandoff: pasteFocusHandoff,
            onClose: { [weak self] in self?.requestUnpin(record.id) },
            onCopyImage: { [weak self] in self?.onCopyImage(record) },
            onDismissShelf: { [weak self] in self?.onDismissShelf() ?? false },
            onFrameChanged: { [weak self] frame in
                self?.dismissGestureHint(for: record.id)
                self?.scheduleFrameSave(frame, for: record.id)
            },
            onOpacityChanged: { [weak self] value in
                self?.dismissGestureHint(for: record.id)
                self?.scheduleOpacitySave(value, for: record.id)
            },
            onHover: { [weak self] in self?.hover(record.id) },
            onHoverEnded: { [weak self] in self?.endHover(record.id) },
            onImageClicked: { [weak self] in self?.bringToFront(record.id) }
        )
        windows[record.id] = window
        window.show()
        installMagnifyMonitorsIfNeeded()
#if DEBUG
        ImageGestureTrace.record("pin show window=\(window.panel.windowNumber) visible=\(window.panel.isVisible) activeSpace=\(window.panel.isOnActiveSpace) frame=\(window.panel.frame) monitors=\(localMagnifyMonitor != nil)/\(backgroundMagnifyMonitor != nil)")
#endif
    }

    func unpin(_ id: UUID) throws {
        if hoveredID == id { hoveredID = nil }
        dismissGestureHint(for: id)
        frameTasks[id]?.cancel()
        frameTasks[id] = nil
        opacityTasks[id]?.cancel()
        opacityTasks[id] = nil
        try store.remove(id)
        windows[id]?.dismiss()
        windows[id] = nil
        if windows.isEmpty { removeMagnifyMonitors() }
        onChange()
    }

    func unpinAll() throws {
        for id in store.records.map(\.id) { try unpin(id) }
    }

    func flushFrames() {
        for (id, window) in windows {
            frameTasks[id]?.cancel()
            opacityTasks[id]?.cancel()
            do {
                try store.updateFrame(window.panel.frame, for: id)
                try store.updateOpacity(window.imageOpacity, for: id)
            } catch {
                onError("保存贴图位置或透明度失败：\(error.localizedDescription)")
            }
        }
        frameTasks.removeAll()
        opacityTasks.removeAll()
    }

    @discardableResult
    func showGestureHint(for id: UUID) -> Bool {
        guard let imageWindow = windows[id], imageWindow.panel.isVisible else { return false }
        dismissGestureHint()
        imageWindow.show()
        let imageFrame = imageWindow.panel.frame
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: imageFrame.midX, y: imageFrame.midY)) }
            ?? NSScreen.screens.first { $0.frame.intersects(imageFrame) }
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = PinnedImageGeometry.gestureHintFrame(
            over: imageFrame, visibleFrame: visibleFrame,
            size: NSSize(width: 294, height: 88)
        )
        let hint = PinnedImageAccessoryPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        hint.isReleasedWhenClosed = false
        hint.level = .screenSaver
        hint.isFloatingPanel = true
        hint.hidesOnDeactivate = false
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.hasShadow = true
        hint.ignoresMouseEvents = true
        hint.collectionBehavior = imageWindow.panel.collectionBehavior
        hint.contentView = NSHostingView(rootView: PinnedGestureHintView())
        gestureHintPanel = hint
        gestureHintForID = id
        hint.orderFrontRegardless()
        gestureHintDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.dismissGestureHint()
        }
        return true
    }

    func dismissGestureHint() {
        gestureHintDismissTask?.cancel()
        gestureHintDismissTask = nil
        gestureHintPanel?.orderOut(nil)
        gestureHintPanel?.close()
        gestureHintPanel = nil
        gestureHintForID = nil
    }

    private func dismissGestureHint(for id: UUID) {
        guard gestureHintForID == id else { return }
        dismissGestureHint()
    }

    private func hover(_ id: UUID) {
        guard let window = windows[id], window.panel.isVisible,
              hoveredID != id else { return }
        if let previous = hoveredID { restoreCommittedPosition(of: previous) }
        hoveredID = id
        // Gesture focus requires a key panel. The temporary order change is
        // restored on mouse exit unless the image is clicked.
        window.show()
    }

    private func endHover(_ id: UUID) {
        guard hoveredID == id else { return }
        hoveredID = nil
        restoreCommittedPosition(of: id)
    }

    private func bringToFront(_ id: UUID) {
        guard let window = windows[id] else { return }
        do {
            try store.bringToFront(id)
            window.show()
        } catch {
            onError("保存贴图层级失败：\(error.localizedDescription)")
        }
    }

    private func restoreCommittedPosition(of id: UUID) {
        guard let index = store.records.firstIndex(where: { $0.id == id }),
              let window = windows[id], window.panel.isVisible else { return }
        // Only move the hovered window. Reordering every pin at once would
        // briefly flash overlapping images and could cover the gesture hint.
        let nextHigherWindow = store.records.dropFirst(index + 1)
            .compactMap { windows[$0.id] }
            .first { $0.panel.isVisible }
        if let nextHigherWindow {
            window.panel.order(.below, relativeTo: nextHigherWindow.panel.windowNumber)
        }
    }

    private func requestUnpin(_ id: UUID) {
        SettingsWindowController.shared.parkForPinnedImageInteraction()
        do { try unpin(id) }
        catch { onError("取消钉住失败：\(error.localizedDescription)") }
    }

    private func installMagnifyMonitorsIfNeeded() {
        if localEscapeMonitor == nil {
            localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == UInt16(kVK_Escape) else { return event }
                var dismissed = false
                MainActor.assumeIsolated {
                    guard let self,
                          self.windows.values.contains(where: {
                              $0.panel.isVisible && $0.panel.windowNumber == event.windowNumber
                          }) else { return }
                    dismissed = self.onDismissShelf()
                }
                return dismissed ? nil : event
            }
        }
        if localMagnifyMonitor == nil {
            localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                var handled = false
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let target = self.pinnedWindowUnderPointer()
#if DEBUG
                    ImageGestureTrace.record("pin local event delta=\(event.magnification) eventWindow=\(event.windowNumber) target=\(target?.panel.windowNumber ?? -1) pointer=\(NSEvent.mouseLocation)")
#endif
                    guard let target else { return }
                    let amount = event.magnification
                    handled = true
                    DispatchQueue.main.async { [weak self, weak target] in
                        guard let self, let target,
                              self.windows.values.contains(where: { $0 === target }) else { return }
                        target.magnify(by: amount)
                    }
                }
                return handled ? nil : event
            }
        }
        if backgroundMagnifyMonitor == nil {
            backgroundMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
                let amount = event.magnification
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let target = self.pinnedWindowUnderPointer()
#if DEBUG
                    ImageGestureTrace.record("pin global event delta=\(amount) target=\(target?.panel.windowNumber ?? -1) pointer=\(NSEvent.mouseLocation)")
#endif
                    target?.magnify(by: amount)
                }
            }
        }
    }

    private func removeMagnifyMonitors() {
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        if let localMagnifyMonitor { NSEvent.removeMonitor(localMagnifyMonitor) }
        if let backgroundMagnifyMonitor { NSEvent.removeMonitor(backgroundMagnifyMonitor) }
        localEscapeMonitor = nil
        localMagnifyMonitor = nil
        backgroundMagnifyMonitor = nil
    }

    private func pinnedWindowUnderPointer() -> PinnedImageWindow? {
        let point = NSEvent.mouseLocation
        let candidates = windows.values.filter { $0.containsImage(atScreenPoint: point) }
        guard !candidates.isEmpty else { return nil }
        // NSApp.orderedWindows omits panels. Window numbers include them in
        // front-to-back order, so only the uppermost overlapping pin responds.
        for number in NSWindow.windowNumbers(options: []) ?? [] {
            if let pinnedWindow = candidates.first(where: { $0.panel.windowNumber == number.intValue }) {
                return pinnedWindow
            }
        }
        // Some Spaces configurations omit nonactivating panels from the list.
        // The panel geometry is still enough to handle a single image under the pointer.
        return candidates.first(where: { $0.panel.isOnActiveSpace }) ?? candidates.first
    }

    private func scheduleFrameSave(_ frame: NSRect, for id: UUID) {
        frameTasks[id]?.cancel()
        frameTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            do { try self.store.updateFrame(frame, for: id) }
            catch { self.onError("保存贴图位置失败：\(error.localizedDescription)") }
            self.frameTasks[id] = nil
        }
    }

    private func scheduleOpacitySave(_ opacity: Double, for id: UUID) {
        opacityTasks[id]?.cancel()
        opacityTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            do { try self.store.updateOpacity(opacity, for: id) }
            catch { self.onError("保存贴图透明度失败：\(error.localizedDescription)") }
            self.opacityTasks[id] = nil
        }
    }

    private func fittedFrame(_ saved: NSRect?, imageSize: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let ratio = imageSize.width / imageSize.height
        let inset = PinnedImageCanvas.shadowInset * 2
        let validSaved = saved.flatMap { frame -> NSRect? in
            guard frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0,
                  frame.width <= PinnedImageGeometry.maximumContentExtent + inset,
                  frame.height <= PinnedImageGeometry.maximumContentExtent + inset else { return nil }
            return frame
        }
        // Preserve a zoomed pin across launches, including sizes larger than
        // the screen. Refit only when its saved position is entirely offscreen.
        let screens = NSScreen.screens.map(\.frame)
        if let validSaved, screens.contains(where: { $0.intersects(validSaved) }) {
            return PinnedImageGeometry.reachableFrame(validSaved, imageRatio: ratio, screens: screens)
        }
        let targetScreen = validSaved.flatMap { proposed in
            NSScreen.screens.first { $0.visibleFrame.intersects(proposed) }
        } ?? screen
        let bounds = targetScreen?.visibleFrame ?? visible
        let maximumWidth = min(PinnedImageGeometry.contentWidthRange(imageRatio: ratio).upperBound,
                               max(1, bounds.width - inset - 20),
                               max(1, bounds.height - inset - 20) * ratio)
        let preferredWidth = min(520, max(140, 410 * sqrt(ratio)))
        let desiredWidth = validSaved.map { max(32, $0.width - inset) } ?? preferredWidth
        let width = min(maximumWidth, max(min(40, maximumWidth), desiredWidth))
        let size = NSSize(width: width + inset, height: width / ratio + inset)
        let center = validSaved.map { NSPoint(x: $0.midX, y: $0.midY) }
            ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let x = min(max(center.x - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let y = min(max(center.y - size.height / 2, bounds.minY), bounds.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func displayImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(
            width: thumbnail.width, height: thumbnail.height
        ))
    }
}
