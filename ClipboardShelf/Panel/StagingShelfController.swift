import AppKit
import ImageIO
import OSLog
import QuickLookUI
import QuickLookThumbnailing
import QuartzCore
import UniformTypeIdentifiers

typealias StagingShelfPreviewContentFactory = (StagingShelfPreviewSession, PreviewTail, CGFloat) -> NSView

@MainActor
final class StagingShelfController {
#if DEBUG
    private static let exportLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ClipHoook", category: "StagingDrag")
#endif
    let store: StagingShelfStore
    var isBlocked: (() -> Bool)?
    var onChange: (() -> Void)?
    var makePreviewContent: StagingShelfPreviewContentFactory?
    private var panel: StagingShelfPanel?
    private var body: StagingShelfView?
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var globalKeyMonitor: Any?
    private var timer: Timer?
    private var dragWatchdog: Timer?
    private var lastNativeDragCheck: TimeInterval = 0
    private let board = NSPasteboard(name: .drag)
    private var gate: StagingDragGate
    private var manual = false
    private var isReceivingDrop = false
    private var screenshotLevel: NSWindow.Level?
    private var lastScreenFrame: NSRect?
    private var selected: Set<UUID> = []
    private var selectionAnchor: UUID?
    private var exportPayload: StagingShelfDragPayload?
    private var exportSource: StagingShelfDragView?
    private var exportSession: NSDraggingSession?
    private var exportToken: UUID?
    private var previousApp: NSRunningApplication?
    private var exportReturnFrame: NSRect?
    private var exportedIDs: Set<UUID> = []
    private var exportEscapeRequested = false
    private var exportEscapeMonitor: Any?
    private var deliveryLeases: [UUID: Task<Void, Never>] = [:]
    private var expandedFrame: NSRect?
    private var targetCollapsed = false
    private var appearancePose: StagingShelfAppearancePose?
    private var appearanceMotion: StagingShelfAppearanceMotion?
    private var appearanceStartedAt: TimeInterval = 0
    private var appearanceDisplayLink: CADisplayLink?
    private var appearanceEdge: StagingShelfPlacement.Edge = .right
    private var edgeSwipe = StagingShelfEdgeSwipe()
    var isCollapsed: Bool { targetCollapsed }
    private var previewCache: [UUID: NSImage] = [:]
    private var thumbnailRequests: [UUID: QLThumbnailGenerator.Request] = [:]
    private var thumbnailAttempts: Set<UUID> = []
    private var previewController: StagingShelfPreviewController?
    private var notice: String?
    private var noticeTask: Task<Void, Never>?
    var isExporting: Bool { exportPayload != nil }

    init(store: StagingShelfStore) {
        self.store = store
        gate = StagingDragGate(changeCount: NSPasteboard(name: .drag).changeCount)
        store.onChange = { [weak self] in
            guard let self else { return }
            let ids = Set(self.store.items.map(\.id))
            self.selected.formIntersection(ids)
            if let anchor = self.selectionAnchor, !ids.contains(anchor) { self.selectionAnchor = nil }
            self.previewCache = self.previewCache.filter { ids.contains($0.key) }
            for id in Array(self.thumbnailRequests.keys) where !ids.contains(id) {
                if let request = self.thumbnailRequests.removeValue(forKey: id) { QLThumbnailGenerator.shared.cancel(request) }
            }
            self.thumbnailAttempts.formIntersection(ids)
            self.refresh()
            if self.store.items.isEmpty && !self.isReceivingDrop { self.hide() }
            else { self.refreshOpenPreview() }
            self.onChange?()
        }
    }

    func start() {
        guard localMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
        // Mouse monitoring works without keyboard or Accessibility permission.
        // The optional key monitor only observes Esc if the OS permits it.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .scrollWheel, .swipe]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                if self?.handleEdgeGesture(event) == true { return true }
                self?.observe(event)
                return false
            }
            return handled ? nil : event
        }
        updateDragWatchdog()
    }

    private func observe(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            gate.mouseDown(changeCount: board.changeCount)
            lastNativeDragCheck = 0
            if StagingShelfPreference.autoReveal() { startTimer() }
        } else if event.type == .leftMouseDragged {
            // Recover when Dock's nested tracking loop did not forward down.
            // Do not replace the idle pasteboard baseline during a drag.
            if StagingShelfPreference.autoReveal() { startTimer() }
        } else if event.type == .leftMouseUp {
            // CoreDrag may deliver mouse-up before performDragOperation.
            DispatchQueue.main.async { [weak self] in self?.pollDrag() }
        } else if event.type == .keyDown, event.keyCode == 53 {
            gate.suppressUntilRelease()
            if isExporting { noteExportEscape() }
            if !isExporting { finishObservedDrag() }
        }
    }

    func internalDragBegan() {
        if StagingShelfPreference.autoReveal() { startTimer() }
    }

    private func updateDragWatchdog() {
        dragWatchdog?.invalidate()
        dragWatchdog = nil
        guard StagingShelfPreference.autoReveal() else { return }
        // Dock can consume both mouse-down and dragged events. This idle check
        // only looks at button state; the pasteboard/window fallback runs while
        // a button is held. Refresh the baseline on release, never mid-drag.
        let watchdog = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer == nil else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    self.startTimer()
                    self.pollDrag()
                } else {
                    _ = self.gate.update(buttonDown: false, changeCount: self.board.changeCount,
                                         supported: false, blocked: false)
                }
            }
        }
        watchdog.tolerance = 0.1
        RunLoop.main.add(watchdog, forMode: .common)
        dragWatchdog = watchdog
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pollDrag() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let wasDragging = gate.isDragging
        let blocked = isExporting || !StagingShelfPreference.autoReveal() || isBlocked?() == true
        var active = gate.update(buttonDown: down, changeCount: board.changeCount,
            supported: down && StagingShelfStore.supports(board),
            blocked: blocked)
        if down, !blocked, gate.needsNativeDragDetection, nativeDragImageUnderPointer() {
            active = gate.update(buttonDown: true, changeCount: board.changeCount,
                                 supported: false, blocked: false, nativeDragDetected: true)
        }
        if active {
            let screen = screenAtPointer()
            if panel?.isVisible != true || screen.frame != lastScreenFrame {
                present(on: screen)
            }
        }
        if !down {
            timer?.invalidate()
            timer = nil
            lastNativeDragCheck = 0
            if wasDragging { finishObservedDrag(preservingTargetedDrop: true) }
        }
    }

    private func nativeDragImageUnderPointer() -> Bool {
        // Window metadata is relatively expensive: inspect at most four times
        // per second, and stop as soon as this drag has been recognized.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastNativeDragCheck >= 0.25 else { return false }
        lastNativeDragCheck = now
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let pointer = StagingNativeDragDetection.quartzPointer(NSEvent.mouseLocation,
                                                               primaryScreenTop: primary.frame.maxY)
        return StagingNativeDragDetection.hasDragImage(in: windows, pointer: pointer)
    }

    private func finishObservedDrag(preservingTargetedDrop: Bool = false) {
        // Mouse-up can arrive before CoreDrag prepares or commits the drop.
        // Keep its destination alive until the native drop callback finishes.
        guard !isReceivingDrop, !(preservingTargetedDrop && body?.isTargeted == true) else { return }
        body?.isTargeted = false
        if store.items.isEmpty && !manual { panel?.orderOut(nil) }
    }

    func incomingDragEnded() { finishObservedDrag() }

    func incomingDragOperation(_ pasteboard: NSPasteboard) -> NSDragOperation {
        let accepts = !isExporting && StagingShelfStore.supports(pasteboard)
        // CoreDrag must always see the final, stable destination geometry.
        if accepts { expand(animated: false) }
        body?.isTargeted = accepts
        return accepts ? .copy : []
    }

    func incomingDragExited() { body?.isTargeted = false }

    func applyPreferences() {
        if localMonitor != nil { updateDragWatchdog() }
        if !StagingShelfPreference.autoReveal() {
            timer?.invalidate()
            timer = nil
            gate.suppressUntilRelease()
            finishObservedDrag()
        }
    }

    func open() {
        manual = true
        present(on: screenAtPointer())
    }

    private func handleEdgeGesture(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, panel.isVisible, !isCollapsed,
              !isExporting, screenshotLevel == nil, isBlocked?() != true,
              let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) else { return false }
        let edge = StagingShelfPlacement.edge(for: panel.frame, in: screen.visibleFrame)
        if event.type == .swipe {
            guard abs(event.deltaX) > abs(event.deltaY),
                  edge == .left ? event.deltaX > 0 : event.deltaX < 0 else { return false }
            collapse(); return true
        }
        guard event.type == .scrollWheel, event.hasPreciseScrollingDeltas,
              event.momentumPhase.isEmpty else { return false }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { edgeSwipe.reset() }
        let matched = edgeSwipe.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            inverted: event.isDirectionInvertedFromDevice, edge: edge)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { edgeSwipe.reset() }
        if matched { collapse() }
        return matched
    }

    func collapse(animated: Bool = true) {
        guard let panel, panel.isVisible, !isCollapsed, !isExporting, !store.items.isEmpty,
              screenshotLevel == nil, isBlocked?() != true,
              let screen = panel.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) else { return }
        previewController?.dismiss(notify: false)
        let fullFrame = expandedFrame ?? panel.frame
        expandedFrame = fullFrame
        targetCollapsed = true
        appearanceEdge = StagingShelfPlacement.edge(for: fullFrame, in: screen.visibleFrame)
        gate.suppressUntilRelease()
        transitionAppearance(toCollapsed: true, fullFrame: fullFrame,
            tabFrame: StagingShelfPlacement.collapsedFrame(for: fullFrame, in: screen.visibleFrame), animated: animated)
    }

    func expand(animated: Bool = true) {
        guard isCollapsed, let frame = expandedFrame else {
            if !animated { finishAppearance() }
            return
        }
        let tabFrame = appearanceMotion?.tabFrame ?? panel?.frame ?? .zero
        targetCollapsed = false
        transitionAppearance(toCollapsed: false, fullFrame: frame, tabFrame: tabFrame, animated: animated)
        refresh()
        panel?.orderFrontRegardless()
        edgeSwipe.reset()
    }

    private func transitionAppearance(toCollapsed: Bool, fullFrame: NSRect, tabFrame: NSRect, animated: Bool) {
        guard let panel else { return }
        appearanceDisplayLink?.invalidate()
        // WindowServer may round origins/alpha to display precision. Resume
        // from the actual window values, including a rapid mid-frame reversal.
        let from = StagingShelfAppearancePose(frame: panel.frame, opacity: panel.alphaValue,
                                             collapsed: appearancePose?.collapsed ?? !toCollapsed)
        appearancePose = from
        let motion = StagingShelfAppearanceMotion(from: from, expandedFrame: fullFrame, tabFrame: tabFrame,
            targetCollapsed: toCollapsed, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        appearanceMotion = motion
        appearanceStartedAt = CACurrentMediaTime()
        guard animated else { finishAppearance(); return }
        // AppKit's display link follows the panel's display and refresh rate,
        // including ProMotion/external screens, and stops after this transition.
        let target = StagingShelfAppearanceDisplayTarget(controller: self)
        let link = panel.displayLink(target: target, selector: #selector(StagingShelfAppearanceDisplayTarget.tick(_:)))
        appearanceDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    fileprivate func advanceAppearance(at timestamp: TimeInterval) {
        guard let motion = appearanceMotion else { return }
        let elapsed = max(0, timestamp - appearanceStartedAt)
        applyAppearance(motion.pose(at: elapsed))
        if elapsed >= motion.duration { finishAppearance() }
    }

    private func applyAppearance(_ pose: StagingShelfAppearancePose) {
        guard let panel else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layoutChanged = appearancePose?.collapsed != pose.collapsed
        if layoutChanged {
            panel.alphaValue = 0
            body?.setCollapsed(pose.collapsed, edge: appearanceEdge)
        }
        if panel.frame != pose.frame { panel.setFrame(pose.frame, display: true) }
        if layoutChanged { body?.layoutSubtreeIfNeeded() }
        panel.alphaValue = pose.opacity
        appearancePose = pose
        CATransaction.commit()
    }

    private func finishAppearance() {
        appearanceDisplayLink?.invalidate()
        appearanceDisplayLink = nil
        if let motion = appearanceMotion { applyAppearance(motion.finalPose) }
        appearanceMotion = nil
        if !targetCollapsed { expandedFrame = nil }
    }

    private func cancelAppearance() {
        appearanceDisplayLink?.invalidate()
        appearanceDisplayLink = nil
        appearanceMotion = nil
        appearancePose = nil
    }

    func beginScreenshotInteraction() {
        gate.suppressUntilRelease()
        finishAppearance()
        guard screenshotLevel == nil else { return }
        if let panel, panel.isVisible {
            screenshotLevel = panel.level
            panel.level = NSWindow.Level(rawValue: PanelLayout.screenshotBackgroundWindowLevel(for: panel.level.rawValue))
        }
        previewController?.beginScreenshotInteraction()
    }

    func endScreenshotInteraction() {
        if let screenshotLevel { panel?.level = screenshotLevel }
        screenshotLevel = nil
        previewController?.endScreenshotInteraction()
    }

    func hide() {
        gate.suppressUntilRelease()
        manual = false
        previewController?.dismiss(notify: false)
        cancelAppearance()
        panel?.orderOut(nil)
        if let expandedFrame { panel?.setFrame(expandedFrame, display: false) }
        expandedFrame = nil
        targetCollapsed = false
        body?.setCollapsed(false)
        panel?.alphaValue = 1
        edgeSwipe.reset()
    }

    private func screenAtPointer() -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func present(on screen: NSScreen, pointer: NSPoint? = nil) {
        guard !isExporting else { return }
        cancelAppearance()
        if panel == nil {
            let window = StagingShelfPanel(contentRect: .zero,
                styleMask: StagingShelfPanel.sourceStyleMask, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.becomesKeyOnlyIfNeeded = false
            window.hidesOnDeactivate = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = NSWindow.Level(rawValue: min(PanelLayout.shelfWindowLevel + 2,
                                                        Int(CGWindowLevelForKey(.draggingWindow)) - 1))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.title = "ClipHoook 暂存箱"
            let content = StagingShelfView(controller: self)
            window.contentView = content
            panel = window
            body = content
        }
        lastScreenFrame = screen.frame
        expandedFrame = nil
        targetCollapsed = false
        body?.setCollapsed(false)
        let frame = StagingShelfPlacement.frame(pointer: pointer ?? NSEvent.mouseLocation, visibleFrame: screen.visibleFrame,
                                                size: StagingShelfPlacement.defaultSize)
        panel?.setFrame(frame, display: true)
        panel?.alphaValue = 1
        panel?.ignoresMouseEvents = false
        appearancePose = StagingShelfAppearancePose(frame: frame, opacity: 1, collapsed: false)
        refresh()
        panel?.orderFrontRegardless()
    }

    private func refresh() {
        body?.reload(items: store.items, selected: selected, notice: notice ?? store.error)
    }

    func preview(for item: StagingShelfItem) -> NSImage {
        if let image = previewCache[item.id] { return image }
        let image: NSImage
        if let url = store.imageURL(for: item),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
           ] as CFDictionary) {
            image = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
        } else if let path = item.filePath {
            image = NSWorkspace.shared.icon(forFile: path)
            requestFileThumbnail(for: item)
        } else {
            image = NSImage(systemSymbolName: item.kind == .link ? "link" : "doc.text", accessibilityDescription: nil)!
        }
        previewCache[item.id] = image
        return image
    }

    private func requestFileThumbnail(for item: StagingShelfItem) {
        guard !thumbnailAttempts.contains(item.id), let path = item.filePath,
              let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension),
              type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie),
              let access = store.fileAccess(for: item) else { return }
        thumbnailAttempts.insert(item.id)
        let request = QLThumbnailGenerator.Request(fileAt: access.url,
            size: NSSize(width: 80, height: 80), scale: 2, representationTypes: .thumbnail)
        thumbnailRequests[item.id] = request
        let complete: @MainActor @Sendable (CGImage?) -> Void = { [weak self] image in
            // Request/access objects stay on the main actor; only immutable
            // image pixels cross the system thumbnail callback boundary.
            withExtendedLifetime(access) {
                guard let self, self.thumbnailRequests[item.id] === request else { return }
                self.thumbnailRequests[item.id] = nil
                guard self.store.items.contains(where: { $0.id == item.id }), let image else { return }
                self.previewCache[item.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                self.refresh()
            }
        }
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.cgImage
            Task { @MainActor in complete(image) }
        }
    }

    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else if modifiers.contains(.shift), let anchor = selectionAnchor,
                  let a = store.items.firstIndex(where: { $0.id == anchor }),
                  let b = store.items.firstIndex(where: { $0.id == id }) {
            selected.formUnion(store.items[min(a, b)...max(a, b)].map(\.id))
        } else if !selected.contains(id) { selected = [id] }
        selectionAnchor = id
        refresh()
        refreshOpenPreview()
    }

    func selectAll() { selected = Set(store.items.map(\.id)); refresh(); refreshOpenPreview() }

    private var previewSelectionID: UUID? {
        if let selectionAnchor, selected.contains(selectionAnchor) { return selectionAnchor }
        return store.items.first { selected.contains($0.id) }?.id
    }

    private func selectedPreviewPayload() throws -> StagingShelfPreviewPayload? {
        guard let id = previewSelectionID else { return nil }
        return try store.previewPayload(id: id)
    }

    private func refreshOpenPreview() {
        guard previewController?.isVisible == true else { return }
        do {
            guard let payload = try selectedPreviewPayload() else { previewController?.dismiss(); return }
            previewController?.show(payload, on: panel?.screen ?? screenAtPointer(),
                shelfFrame: panel?.frame ?? .zero, itemFrame: body?.screenFrame(for: payload.id), activate: false)
        } catch {
            previewController?.dismiss()
            showNotice(error.localizedDescription)
        }
    }

    private func togglePreview() {
        if previewController?.isVisible == true { previewController?.dismiss(); return }
        finishAppearance()
        do {
            guard let payload = try selectedPreviewPayload() else { return }
            if previewController == nil {
                let preview = StagingShelfPreviewController()
                preview.onClose = { [weak self] in
                    guard let self, self.panel?.isVisible == true, !self.isExporting else { return }
                    self.panel?.makeKey()
                    self.panel?.makeFirstResponder(self.body)
                }
                previewController = preview
            }
            previewController?.makeContent = makePreviewContent
            previewController?.show(payload, on: panel?.screen ?? screenAtPointer(),
                shelfFrame: panel?.frame ?? .zero, itemFrame: body?.screenFrame(for: payload.id))
        } catch { showNotice(error.localizedDescription) }
    }

    func closePreview() { previewController?.dismiss() }

    func beginContentInteraction() -> () -> Void {
        finishAppearance()
        closePreview()
        let window = panel
        let level = window?.level
        let floating = window?.isFloatingPanel
        window?.isFloatingPanel = false
        window?.level = .normal
        return {
            if let level { window?.level = level }
            if let floating { window?.isFloatingPanel = floating }
        }
    }

    func copyItem(_ id: UUID) {
        do {
            let payload = try store.dragPayload(ids: [id])
            let board = NSPasteboard.general
            board.clearContents()
            guard board.writeObjects(payload.writers) else { throw StagingShelfError.unavailable }
            withExtendedLifetime(payload) { showNotice("已复制") }
        } catch { showNotice(error.localizedDescription) }
    }

    func remove(_ ids: Set<UUID>) {
        guard !isExporting else { return }
        do {
            try store.remove(ids)
            if store.items.isEmpty { hide() }
        } catch { showNotice(error.localizedDescription) }
    }

    func confirmClear() {
        guard !isExporting, !store.items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清空暂存箱？"
        alert.informativeText = "移除暂存内容。原文件和剪贴板历史保持不变。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.window.level = NSWindow.Level(rawValue: PanelLayout.shelfWindowLevel + 3)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        remove(Set(store.items.map(\.id)))
    }

    @discardableResult
    func receive(_ pasteboard: NSPasteboard) -> Bool {
        guard !isExporting else { return false }
        expand(animated: false)
        isReceivingDrop = true
        defer { isReceivingDrop = false }
        do {
            let count = try store.receive(pasteboard)
            // A completed drop keeps the shelf open, just like opening it
            // manually. Also recover if an earlier mouse-up already hid it.
            manual = true
            gate.suppressUntilRelease()
            showNotice(count > 0 ? "已暂存 \(count) 项" : "内容已在暂存箱中")
            body?.isTargeted = false
            panel?.alphaValue = 1
            panel?.ignoresMouseEvents = false
            panel?.orderFrontRegardless()
            return true
        } catch {
            manual = true
            showNotice(error.localizedDescription)
            present(on: panel?.screen ?? screenAtPointer())
            return false
        }
    }

    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        notice = text
        refresh()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.notice = nil
            self.refresh()
            if self.store.items.isEmpty { self.hide() }
        }
    }

    func beginExport(from source: StagingShelfDragView, itemID: UUID?, event: NSEvent,
                     gesture: NSGestureRecognizer? = nil) {
        guard !isExporting, !store.items.isEmpty else { return }
        finishAppearance()
        let ids = itemID.map { selected.contains($0) ? selected : [$0] } ?? Set(store.items.map(\.id))
        do {
            let payload = try store.dragPayload(ids: ids)
            previewController?.dismiss(notify: false)
            exportPayload = payload
            exportedIDs = ids
            exportEscapeRequested = false
            let token = UUID()
            exportToken = token
            exportSource = source
            exportReturnFrame = panel?.frame
            previousApp = NSWorkspace.shared.frontmostApplication
            gate.suppressUntilRelease()
            let selectedItems = store.items.filter { ids.contains($0.id) }
            let dragItems = zip(payload.writers, selectedItems).enumerated().map { offset, pair in
                let item = NSDraggingItem(pasteboardWriter: pair.0)
                let point = gesture?.location(in: source) ?? source.convert(event.locationInWindow, from: nil)
                item.setDraggingFrame(NSRect(x: point.x - 24 + CGFloat(min(offset, 3)) * 3,
                                             y: point.y - 24, width: 48, height: 48), contents: preview(for: pair.1))
                return item
            }
            installExportEscapeMonitor()
            traceExport(gesture == nil ? "begin-event" : "begin-gesture")
            let session: NSDraggingSession?
            if #available(macOS 27.0, *), let gesture {
                // Do not change application/key-window focus in the middle
                // of a recognizer-owned press. AppKit owns this handoff.
                session = source.beginDraggingSession(items: dragItems, gesture: gesture, source: source)
            } else {
                source.prepareExportKeyboardFocus()
                session = source.beginDraggingSession(with: dragItems, event: event, source: source)
            }
            // A native tracking loop may finish before this call returns.
            // Never retain a returned session after its end callback ran, or
            // overwrite a subsequent drag's session with that old return.
            guard exportToken == token, isExporting else { return }
            guard let session else { exportEnded(operation: []); return }
            exportSession = session
        } catch { showNotice(error.localizedDescription) }
    }

    func exportStarted() {
        // This narrow shelf stays in place throughout a native drag. Moving
        // a nonactivating key panel off every display made cancellation depend
        // on borrowed focus and on the timing of native tracking startup.
        // Do not hide, move, or make the source window ignore input here.
        traceExport("will-begin")
    }

    private func installExportEscapeMonitor() {
        removeExportEscapeMonitor()
        // Observe only. Reserving Escape globally consumes the physical key
        // before CoreDrag sees it; an app-local repost is not a reliable
        // substitute inside the native tracking loop.
        exportEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.trackExportKey(event) }
            return event
        }
    }

    private func removeExportEscapeMonitor() {
        if let exportEscapeMonitor { NSEvent.removeMonitor(exportEscapeMonitor) }
        exportEscapeMonitor = nil
    }

    func trackExportKey(_ event: NSEvent) -> NSEvent {
        if event.type == .keyDown, event.keyCode == 53 { noteExportEscape() }
        return event
    }

    // CoreDrag owns cancellation. An observer must not change a live session's
    // advertised operation or turn a key press into a fabricated final result.
    var exportOperationMask: NSDragOperation { isExporting ? .copy : [] }

    private func noteExportEscape() {
        guard isExporting, !exportEscapeRequested else { return }
        exportEscapeRequested = true
        gate.suppressUntilRelease()
        traceExport("escape-observed")
    }

    func exportEnded(operation: NSDragOperation) {
        guard isExporting else { return }
        traceExport("ended-\(operation.rawValue)")
        removeExportEscapeMonitor()
        let source = exportSource
        exportToken = nil
        exportSession = nil
        // An observed Escape is only a request. CoreDrag's final operation is
        // authoritative: some destinations may finish an already accepted drop
        // after that key. Do not leave a delivered item in the shelf merely
        // because our key monitor ran before the completion callback.
        let completed = !operation.intersection([.copy, .move, .link, .generic]).isEmpty
        let ids = exportedIDs
        if completed, let accesses = exportPayload?.accesses, !accesses.isEmpty {
            let lease = UUID()
            deliveryLeases[lease] = Task { @MainActor [weak self, accesses] in
                try? await Task.sleep(for: .seconds(60))
                withExtendedLifetime(accesses) {}
                self?.deliveryLeases[lease] = nil
            }
        }
        exportPayload = nil
        exportSource = nil
        source?.finishExportGesture()
        exportedIDs = []
        exportEscapeRequested = false
        panel?.alphaValue = 1
        panel?.ignoresMouseEvents = false
        if completed {
            do { try store.remove(ids, afterSuccessfulExport: true) }
            catch { showNotice("已投放，但暂存项未能移除：\(error.localizedDescription)") }
        }
        let anchor = exportReturnFrame.map { NSPoint(x: $0.midX, y: $0.midY) }
        let sourceScreen = anchor.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
        if !store.items.isEmpty {
            if sourceScreen != nil, let originalFrame = exportReturnFrame, let panel {
                panel.setFrame(originalFrame, display: true)
                refresh()
                panel.orderFrontRegardless()
            } else { present(on: screenAtPointer()) }
        }
        exportReturnFrame = nil
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
        previousApp = nil
    }

    private func traceExport(_ phase: String) {
#if DEBUG
        // Sparse metadata stays available after normal use without a live log
        // stream, so diagnostics do not require reproducing under observation.
        Self.exportLogger.notice("phase=\(phase, privacy: .public) active=\(NSApp.isActive) key=\(self.panel?.isKeyWindow == true) window=\(self.panel?.windowNumber ?? 0) keyWindow=\(NSApp.keyWindow?.windowNumber ?? 0) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) alpha=\(self.panel?.alphaValue ?? -1) source=\(self.exportSource?.inputTrackingDescription ?? "none", privacy: .public) exporting=\(self.isExporting) escapeRequested=\(self.exportEscapeRequested)")
#endif
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if isExporting {
            if event.keyCode == 53 { observe(event) }
            return false // CoreDrag must receive Escape itself.
        }
        if event.keyCode == 53 {
            if previewController?.isVisible == true { previewController?.dismiss() }
            else { hide() }
            return true
        }
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !selected.isEmpty {
            if !event.isARepeat { togglePreview() }
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "a" {
            selectAll(); return true
        }
        if event.keyCode == 51 || event.keyCode == 117 { remove(selected); return true }
        return false
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let exportEscapeMonitor { NSEvent.removeMonitor(exportEscapeMonitor) }
        timer?.invalidate()
        dragWatchdog?.invalidate()
        appearanceDisplayLink?.invalidate()
        for request in thumbnailRequests.values { QLThumbnailGenerator.shared.cancel(request) }
        noticeTask?.cancel()
        for lease in deliveryLeases.values { lease.cancel() }
    }
}

@MainActor
private final class StagingShelfAppearanceDisplayTarget: NSObject {
    private weak var controller: StagingShelfController?
    init(controller: StagingShelfController) { self.controller = controller }
    @objc func tick(_ link: CADisplayLink) { controller?.advanceAppearance(at: link.targetTimestamp) }
}

private final class StagingShelfPanel: NSPanel {
    // Showing a drop destination with orderFrontRegardless does not activate
    // the app. An actual click, however, must give native dragging real focus
    // before AppKit starts tracking; do not borrow it via nonactivatingPanel.
    static let sourceStyleMask: NSWindow.StyleMask = [.borderless]
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class StagingShelfPreviewPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 53 || (event.keyCode == 49 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty) {
            if !event.isARepeat { onDismiss?() }
            return
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

@MainActor
private final class StagingShelfPreviewController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    var makeContent: StagingShelfPreviewContentFactory?
    private var panel: StagingShelfPreviewPanel?
    private var renderer: QLPreviewView?
    private var payload: StagingShelfPreviewPayload?
    private var session: StagingShelfPreviewSession?
    private var tail = PreviewTail(edge: .left, offset: 60)
    private var backingScale: CGFloat = 1
    private var screenshotLevel: NSWindow.Level?
    var isVisible: Bool { payload != nil && panel?.isVisible == true }

    func show(_ payload: StagingShelfPreviewPayload, on screen: NSScreen,
              shelfFrame: CGRect, itemFrame: CGRect?, activate: Bool = true) {
        if panel == nil {
            let window = StagingShelfPreviewPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.isFloatingPanel = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.level = NSWindow.Level(rawValue: PanelLayout.shelfWindowLevel + 3)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.delegate = self
            window.onDismiss = { [weak self] in self?.dismiss() }
            panel = window
        }
        let placement: PanelPlacement = shelfFrame.midX < screen.visibleFrame.midX ? .left : .right
        let anchor = itemFrame ?? shelfFrame
        let preferred: CGSize
        if case .text(let text) = payload.content { preferred = PanelLayout.textPreviewPreferredSize(for: text) }
        else if payload.previewEntry.kind == .image {
            let available = PanelLayout.detailPreviewAvailableSize(in: screen.visibleFrame, avoiding: shelfFrame,
                placement: placement, cardFrame: anchor)
            var pixels: CGSize?
            if case .file(let url) = payload.content,
               let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
               let height = properties[kCGImagePropertyPixelHeight] as? CGFloat { pixels = CGSize(width: width, height: height) }
            preferred = PanelLayout.imagePreviewPreferredSize(pixelSize: pixels, backingScale: screen.backingScaleFactor,
                availableSize: available, placement: placement, isFileReference: false)
        } else { preferred = CGSize(width: 860, height: 660) }
        let frame = PanelLayout.detailPreviewFrame(in: screen.visibleFrame, avoiding: shelfFrame,
            placement: placement, preferredSize: preferred, cardFrame: anchor)
        tail = PanelLayout.previewTail(previewFrame: frame, cardFrame: anchor, placement: placement)
        backingScale = screen.backingScaleFactor
        panel?.setFrame(frame, display: true)
        setContent(payload)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        }
        panel?.invalidateShadow()
    }

    func setContent(_ payload: StagingShelfPreviewPayload) {
        if self.payload?.id == payload.id { self.payload = payload; session?.update(payload); return }
        clearContent()
        guard let panel else { return }
        self.payload = payload
        let session = StagingShelfPreviewSession(payload)
        self.session = session
        panel.title = payload.name.isEmpty ? "暂存内容预览" : payload.name
        if let makeContent {
            panel.contentView = makeContent(session, tail, backingScale)
            return
        }
        let bounds = NSRect(origin: .zero, size: panel.contentLayoutRect.size)
        switch payload.content {
        case .file(let url):
            if let preview = QLPreviewView(frame: bounds, style: .normal) {
                preview.shouldCloseWithWindow = false
                preview.autostarts = false
                preview.autoresizingMask = [.width, .height]
                preview.previewItem = url as NSURL
                panel.contentView = preview
                renderer = preview
            } else {
                panel.contentView = NSTextField(labelWithString: "暂不支持预览此文件")
            }
        case .text(let text):
            let scroll = NSScrollView(frame: bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            let content = NSTextView(frame: bounds)
            content.isEditable = false
            content.isSelectable = true
            content.isRichText = false
            content.drawsBackground = false
            content.font = .systemFont(ofSize: 14)
            content.textColor = .labelColor
            content.textContainerInset = NSSize(width: 14, height: 14)
            content.isVerticallyResizable = true
            content.isHorizontallyResizable = false
            content.autoresizingMask = .width
            content.textContainer?.widthTracksTextView = true
            content.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
            content.string = text
            scroll.documentView = content
            panel.contentView = scroll
        }
    }

    func dismiss(notify: Bool = true) {
        guard payload != nil else { return }
        panel?.orderOut(nil)
        clearContent()
        if notify { onClose?() }
    }

    func beginScreenshotInteraction() {
        guard screenshotLevel == nil, let panel, panel.isVisible else { return }
        screenshotLevel = panel.level
        panel.level = NSWindow.Level(rawValue: PanelLayout.screenshotBackgroundWindowLevel(for: panel.level.rawValue))
    }

    func endScreenshotInteraction() {
        if let screenshotLevel { panel?.level = screenshotLevel }
        screenshotLevel = nil
    }

    private func clearContent() {
        // The security scope is held until the renderer has released its item.
        renderer?.close()
        renderer = nil
        session?.cancelRecognition()
        session = nil
        panel?.contentView = nil
        payload = nil
    }

    func windowWillClose(_ notification: Notification) {
        clearContent()
        onClose?()
    }
}

class StagingShelfDragView: NSView, NSDraggingSource, NSGestureRecognizerDelegate {
    static let incomingTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .URL, .string,
        NSPasteboard.PasteboardType("NSFilenamesPboardType")]
    weak var controller: StagingShelfController?
    var itemID: UUID?
    private var down: NSPoint?
    private var downEvent: NSEvent?
    private var exportGesture: ContentDragGestureRecognizer?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Both each item and the background are drop targets. A drag source
        // view must not become a dead zone for incoming files.
        registerForDraggedTypes(Self.incomingTypes)
        let gesture = ContentDragGestureRecognizer(target: self, action: #selector(handleExportGesture(_:)))
        gesture.delegate = self
        addGestureRecognizer(gesture)
        exportGesture = gesture
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func pointerDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil)
        downEvent = event
        if #available(macOS 27.0, *) { window?.makeFirstResponder(self) }
        else { prepareExportKeyboardFocus() }
        if let itemID { controller?.select(itemID, modifiers: event.modifierFlags) }
    }
    func prepareExportKeyboardFocus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
    }
    func pointerDragged(with event: NSEvent, gesture: NSGestureRecognizer? = nil) {
        guard let down else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - down.x, point.y - down.y) >= 5 else { return }
        self.down = nil
        controller?.beginExport(from: self, itemID: itemID, event: downEvent ?? event, gesture: gesture)
    }
    func pointerUp(with event: NSEvent) {
        down = nil
        downEvent = nil
    }
    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard gestureRecognizer === exportGesture, event.type == .leftMouseDown else { return false }
        let point = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        // The root also contains draggable rows. Only the actual hit row (or
        // title/background) may start a gesture; child buttons remain clickable.
        return hitTest(point) === self
    }
    @objc private func handleExportGesture(_ gesture: ContentDragGestureRecognizer) {
        guard gesture === exportGesture, let event = gesture.pointerEvent else { return }
        switch gesture.state {
        case .began: pointerDown(with: event)
        case .changed: pointerDragged(with: event, gesture: gesture)
        case .ended: pointerUp(with: event)
        case .cancelled, .failed:
            if controller?.isExporting != true { pointerUp(with: event) }
        default: break
        }
    }
    var inputTrackingDescription: String {
        "window=\(window?.windowNumber ?? 0) \(exportGesture?.trackingDescription ?? "none")"
    }
    func finishExportGesture() {
        down = nil
        downEvent = nil
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        controller?.exportOperationMask ?? []
    }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        session.animatesToStartingPositionsOnCancelOrFail = false
        controller?.exportStarted()
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.exportEnded(operation: operation)
        finishExportGesture()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.incomingDragOperation(sender.draggingPasteboard) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.incomingDragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggingEntered(sender) != []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.incomingDragExited()
        return controller?.receive(sender.draggingPasteboard) == true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.incomingDragExited()
        controller?.incomingDragEnded()
    }
}

private final class StagingShelfRow: StagingShelfDragView {
    let item: StagingShelfItem
    private let artwork: NSImageView
    private let title: NSTextField
    private let removeButton: NSButton
    private var hoverArea: NSTrackingArea?
    var selected = false { didSet { needsDisplay = true } }
    init(item: StagingShelfItem, controller: StagingShelfController) {
        self.item = item
        artwork = NSImageView(image: controller.preview(for: item))
        title = NSTextField(labelWithString: item.name.isEmpty ? "文字" : item.name)
        removeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除")!, target: nil, action: nil)
        super.init(frame: .zero)
        self.controller = controller
        itemID = item.id
        artwork.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        removeButton.isBordered = false
        removeButton.isHidden = true
        removeButton.target = self
        removeButton.action = #selector(removeItem)
        removeButton.toolTip = "移出暂存箱，保留原文件"
        for view in [artwork, title, removeButton] { addSubview(view) }
        toolTip = item.filePath ?? item.text ?? item.name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.name)
        setAccessibilityHelp("空格预览；可拖到其他应用；Command 点击可多选")
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { removeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { removeButton.isHidden = true }
    @objc private func removeItem() { controller?.remove([item.id]) }
    func updateArtwork(_ image: NSImage) { artwork.image = image }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === removeButton || hit.isDescendant(of: removeButton) ? hit : self
    }
    override func layout() {
        super.layout()
        let side = min(StagingShelfGridLayout.thumbnailSize, max(1, bounds.width - 12))
        artwork.frame = NSRect(x: (bounds.width - side) / 2, y: 30, width: side, height: side)
        title.frame = NSRect(x: 5, y: 8, width: max(1, bounds.width - 10), height: 16)
        removeButton.frame = NSRect(x: bounds.width - 21, y: bounds.height - 22, width: 18, height: 18)
    }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
        }
    }
}

private final class StagingShelfDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class StagingShelfView: StagingShelfDragView {
    private let backdrop: NSView
    private let heading = NSTextField(labelWithString: "暂存箱")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let document = StagingShelfDocumentView()
    private let closeButton: NSButton
    private let clearButton: NSButton
    private let edgeButton: NSButton
    private var collapsed = false
    private var rows: [StagingShelfRow] = []
    var isTargeted = false {
        didSet {
            layer?.borderWidth = isTargeted ? 2 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    init(controller: StagingShelfController) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            if #available(macOS 27.0, *) { glass.effectIsInteractive = false }
            backdrop = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            backdrop = material
        }
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "隐藏暂存箱")!, target: nil, action: nil)
        clearButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "清空暂存箱")!, target: nil, action: nil)
        edgeButton = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "展开暂存箱")!, target: nil, action: nil)
        super.init(frame: .zero)
        self.controller = controller
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        for button in [closeButton, clearButton, edgeButton] { button.isBordered = false; button.target = self }
        closeButton.action = #selector(close)
        clearButton.action = #selector(clear)
        edgeButton.action = #selector(expand)
        edgeButton.isHidden = true
        edgeButton.toolTip = "展开暂存箱"
        closeButton.toolTip = "隐藏；暂存内容仍保留"
        clearButton.toolTip = "清空暂存箱"
        for view in [backdrop, heading, scroll, status, closeButton, clearButton, edgeButton] { addSubview(view) }
        setAccessibilityLabel("ClipHoook 暂存箱")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func close() { controller?.hide() }
    @objc private func clear() { controller?.confirmClear() }
    @objc private func expand() { controller?.expand() }

    func setCollapsed(_ collapsed: Bool, edge: StagingShelfPlacement.Edge = .right) {
        self.collapsed = collapsed
        for view in [heading, scroll, status, closeButton, clearButton] { view.isHidden = collapsed }
        edgeButton.isHidden = !collapsed
        edgeButton.image = NSImage(systemSymbolName: edge == .left ? "chevron.right" : "chevron.left",
                                   accessibilityDescription: "展开暂存箱")
        layer?.cornerRadius = collapsed ? 8 : 20
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView { glass.cornerRadius = collapsed ? 8 : 20 }
        needsLayout = true
    }

    func screenFrame(for id: UUID) -> CGRect? {
        guard let row = rows.first(where: { $0.item.id == id }), let window else { return nil }
        row.scrollToVisible(row.bounds)
        layoutSubtreeIfNeeded()
        return window.convertToScreen(row.convert(row.bounds, to: nil))
    }

    func reload(items: [StagingShelfItem], selected: Set<UUID>, notice: String?) {
        heading.stringValue = "暂存箱 · \(items.count)"
        edgeButton.toolTip = "展开暂存箱 · \(items.count) 项"
        status.stringValue = notice ?? (items.isEmpty ? "拖入文件、图片或文字" : "空格预览 · ⌘ 点击多选")
        clearButton.isEnabled = !items.isEmpty
        if rows.map({ $0.item.id }) != items.map(\.id), let controller {
            for row in rows { row.removeFromSuperview() }
            rows = items.map { StagingShelfRow(item: $0, controller: controller) }
            for row in rows { document.addSubview(row) }
        }
        for row in rows {
            row.selected = selected.contains(row.item.id)
            if let controller { row.updateArtwork(controller.preview(for: row.item)) }
        }
        heading.toolTip = "拖动标题可一起取出全部内容"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        edgeButton.frame = bounds
        if collapsed { return }
        heading.frame = NSRect(x: 12, y: bounds.height - 31, width: bounds.width - 72, height: 19)
        closeButton.frame = NSRect(x: bounds.width - 31, y: bounds.height - 32, width: 22, height: 22)
        clearButton.frame = NSRect(x: bounds.width - 56, y: bounds.height - 32, width: 23, height: 22)
        scroll.frame = NSRect(x: 8, y: 50, width: bounds.width - 16, height: max(1, bounds.height - 94))
        let height = StagingShelfGridLayout.contentHeight(count: rows.count, viewportHeight: scroll.contentSize.height)
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: height)
        let frames = StagingShelfGridLayout.frames(count: rows.count, width: document.bounds.width)
        for (row, frame) in zip(rows, frames) {
            row.frame = frame
            row.needsLayout = true
        }
        status.frame = NSRect(x: 14, y: 9, width: bounds.width - 28, height: 32)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === backdrop || hit.isDescendant(of: backdrop) || hit === heading || hit === status { return self }
        return hit
    }
    override func draw(_ dirtyRect: NSRect) {
        guard isTargeted else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18)
        path.lineWidth = 2
        path.stroke()
    }
}
