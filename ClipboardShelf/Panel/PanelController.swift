import AppKit
import SwiftUI

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ShelfHostingView: NSHostingView<ShelfView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One continuous outline joins the rounded card and its small pointing tip.
/// The preview window stays transparent outside this path so AppKit can cast
/// its native window shadow from the visible shape.
private struct PreviewBubbleShape: Shape {
    let tail: PreviewTail

    func path(in rect: CGRect) -> Path {
        let tip: CGFloat = 10
        let base: CGFloat = 12
        let radius: CGFloat = 20
        var body = rect
        switch tail.edge {
        case .bottom: body.size.height -= tip
        case .top: body.origin.y += tip; body.size.height -= tip
        case .left: body.origin.x += tip; body.size.width -= tip
        case .right: body.size.width -= tip
        }
        let x = min(body.maxX - radius - base, max(body.minX + radius + base, rect.minX + tail.offset))
        let y = min(body.maxY - radius - base, max(body.minY + radius + base, rect.minY + tail.offset))
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        if tail.edge == .top {
            path.addLine(to: CGPoint(x: x - base, y: body.minY))
            path.addCurve(to: CGPoint(x: x, y: body.minY - tip),
                          control1: CGPoint(x: x - 5, y: body.minY),
                          control2: CGPoint(x: x - 3, y: body.minY - tip))
            path.addCurve(to: CGPoint(x: x + base, y: body.minY),
                          control1: CGPoint(x: x + 3, y: body.minY - tip),
                          control2: CGPoint(x: x + 5, y: body.minY))
        }
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + radius),
                          control: CGPoint(x: body.maxX, y: body.minY))
        if tail.edge == .right {
            path.addLine(to: CGPoint(x: body.maxX, y: y - base))
            path.addCurve(to: CGPoint(x: body.maxX + tip, y: y),
                          control1: CGPoint(x: body.maxX, y: y - 5),
                          control2: CGPoint(x: body.maxX + tip, y: y - 3))
            path.addCurve(to: CGPoint(x: body.maxX, y: y + base),
                          control1: CGPoint(x: body.maxX + tip, y: y + 3),
                          control2: CGPoint(x: body.maxX, y: y + 5))
        }
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: body.maxX - radius, y: body.maxY),
                          control: CGPoint(x: body.maxX, y: body.maxY))
        if tail.edge == .bottom {
            path.addLine(to: CGPoint(x: x + base, y: body.maxY))
            path.addCurve(to: CGPoint(x: x, y: body.maxY + tip),
                          control1: CGPoint(x: x + 5, y: body.maxY),
                          control2: CGPoint(x: x + 3, y: body.maxY + tip))
            path.addCurve(to: CGPoint(x: x - base, y: body.maxY),
                          control1: CGPoint(x: x - 3, y: body.maxY + tip),
                          control2: CGPoint(x: x - 5, y: body.maxY))
        }
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY - radius),
                          control: CGPoint(x: body.minX, y: body.maxY))
        if tail.edge == .left {
            path.addLine(to: CGPoint(x: body.minX, y: y + base))
            path.addCurve(to: CGPoint(x: body.minX - tip, y: y),
                          control1: CGPoint(x: body.minX, y: y + 5),
                          control2: CGPoint(x: body.minX - tip, y: y + 3))
            path.addCurve(to: CGPoint(x: body.minX, y: y - base),
                          control1: CGPoint(x: body.minX - tip, y: y - 3),
                          control2: CGPoint(x: body.minX, y: y - 5))
        }
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addQuadCurve(to: CGPoint(x: body.minX + radius, y: body.minY),
                          control: CGPoint(x: body.minX, y: body.minY))
        path.closeSubpath()
        return path
    }
}

@MainActor
private final class PreviewBubbleAnchor: ObservableObject {
    @Published var tail = PreviewTail(edge: .bottom, offset: 60)
}

@MainActor
private final class PreviewBubbleMotion: ObservableObject {
    @Published var progress: CGFloat = 1
}

private struct DetailPreviewPanelView: View {
    @ObservedObject var model: AppController
    let entry: ClipboardEntry
    let onKeyDown: (NSEvent) -> Bool
    let onClose: () -> Void
    let backingScale: CGFloat
    @ObservedObject var anchor: PreviewBubbleAnchor
    @ObservedObject var motion: PreviewBubbleMotion

    var body: some View {
        let currentEntry = model.entries.first(where: { $0.id == entry.id })
            ?? model.entries.lazy.filter { $0.kind == .group }
                .flatMap(\.groupMembers).first(where: { $0.id == entry.id })
            ?? entry
        GeometryReader { geometry in
        ClipboardDetailView(
            entry: currentEntry,
            backingScale: backingScale,
            imageURL: model.imageURL(for: currentEntry),
            thumbnailURL: model.thumbnailURL(for: currentEntry),
            richTextFiles: model.richTextSourceFiles(for: currentEntry),
            fileHasSavedCopy: model.fileHasSavedCopy(currentEntry),
            savedCopyName: model.savedCopyDisplayName(for: currentEntry),
            fileReferenceAvailable: model.fileReferenceIsAvailable(currentEntry),
            loadFileReferenceImage: { await model.fileReferencePreviewImage(for: currentEntry) },
            makeFilePreviewAccess: { model.filePreviewAccess(for: currentEntry) },
            onCopy: { model.copy(currentEntry) },
            onRevealOriginalFile: { model.revealOriginalFile(currentEntry) },
            onSaveFileCopy: { model.saveFileCopy(currentEntry) },
            onRepairFromRecentCopy: { model.repairUnavailableImageUsingRecentCopy(currentEntry) },
            onChooseRepairImage: { model.repairUnavailableImageChoosingFile(currentEntry) },
            onDelete: { model.confirmDelete(currentEntry) },
            onImagePreviewAppear: { model.activatePanelForImagePreview() },
            onClose: onClose
        )
        .id("\(entry.id.uuidString)-\(model.panelPresentationID.uuidString)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, anchor.tail.edge == .top ? 10 : 0)
        .padding(.bottom, anchor.tail.edge == .bottom ? 10 : 0)
        .padding(.leading, anchor.tail.edge == .left ? 10 : 0)
        .padding(.trailing, anchor.tail.edge == .right ? 10 : 0)
        .background(.regularMaterial, in: PreviewBubbleShape(tail: anchor.tail))
        .clipShape(PreviewBubbleShape(tail: anchor.tail))
        .overlay {
            PreviewBubbleShape(tail: anchor.tail)
                .stroke(.white.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .scaleEffect(0.025 + 0.975 * motion.progress,
                     anchor: expansionAnchor(in: geometry.size))
        // The fade is confined to the final few points of travel. The bubble
        // remains visible while it actually returns to its source card.
        .opacity(min(1, motion.progress * 12))
        .background {
            ShelfKeyMonitor(onKeyDown: onKeyDown)
                .frame(width: 0, height: 0)
        }
        }
    }

    private func expansionAnchor(in size: CGSize) -> UnitPoint {
        let horizontal = min(1, max(0, anchor.tail.offset / max(1, size.width)))
        let vertical = min(1, max(0, anchor.tail.offset / max(1, size.height)))
        switch anchor.tail.edge {
        case .bottom: return UnitPoint(x: horizontal, y: 1)
        case .top: return UnitPoint(x: horizontal, y: 0)
        case .left: return UnitPoint(x: 0, y: vertical)
        case .right: return UnitPoint(x: 1, y: vertical)
        }
    }
}

private final class DetailHostingView: NSHostingView<DetailPreviewPanelView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController {
    private let panel: ShelfPanel
    private var detailPanel: ShelfPanel?
    private var previewedEntry: ClipboardEntry?
    private var detailCloseAction: (() -> Void)?
    private var previewLocalCardFrame: CGRect?
    private let previewAnchor = PreviewBubbleAnchor()
    private let previewMotion = PreviewBubbleMotion()
    private var detailTransitionGeneration = 0
    private var isDetailEntranceAnimating = false
    // Fixed for the current presentation. Image decoding may change the
    // content, but it must never trigger a second window resize.
    private var previewImagePixelSize: CGSize?
    private var previewTextPreferredSize: CGSize?
    private let model: AppController
    private(set) var previousApplication: NSRunningApplication?
    private(set) var previousTarget: PasteTargetSnapshot?
    private var lastExternalApplication: NSRunningApplication?
    private var targetFrame: NSRect = .zero
    private var displayFrame: NSRect = .zero
    private var currentPlacement: PanelPlacement = .bottom
    private var outsideClickMonitor: Any?
    private var settingsClickMonitor: Any?
    private var activationObserver: Any?
    private var appActivationObserver: Any?
    private var appDeactivationObserver: Any?
    private var isDismissing = false
    private var activatedForImagePreview = false
    private var imagePreviewActivationToken = UUID()
    private var modalInteractionDepth = 0
    private var modalDismissalGraceUntil: TimeInterval = 0
    private var presentationGeneration = 0
    private var shownAtUptime: TimeInterval = 0

    var isVisible: Bool { panel.isVisible }

    private var isModalInteractionActive: Bool {
        modalInteractionDepth > 0 || NSApp.modalWindow != nil ||
            ProcessInfo.processInfo.systemUptime < modalDismissalGraceUntil
    }

    func performModalInteraction<T>(_ present: () -> T) -> T {
        modalInteractionDepth += 1
        // A delayed image-preview activation must not take focus from an alert.
        imagePreviewActivationToken = UUID()
        let hadVisibleShelf = panel.isVisible
        let originalShelfLevel = panel.level
        let originalShelfFloating = panel.isFloatingPanel
        let visiblePreview = detailPanel.flatMap { $0.isVisible ? $0 : nil }
        let originalPreviewLevel = visiblePreview?.level
        let originalPreviewFloating = visiblePreview?.isFloatingPanel
        if hadVisibleShelf {
            // Pre-setting the alert's level did not survive its modal
            // presentation. Temporarily make both background panels ordinary
            // windows, so AppKit's newly ordered alert is in front of them.
            panel.isFloatingPanel = false
            visiblePreview?.isFloatingPanel = false
            panel.level = .normal
            visiblePreview?.level = .normal
            _ = NSRunningApplication.current.activate()
            panel.orderFrontRegardless()
            visiblePreview?.orderFrontRegardless()
        }
        defer {
            if hadVisibleShelf {
                panel.isFloatingPanel = originalShelfFloating
                panel.level = originalShelfLevel
                if let visiblePreview, let originalPreviewFloating, let originalPreviewLevel {
                    visiblePreview.isFloatingPanel = originalPreviewFloating
                    visiblePreview.level = originalPreviewLevel
                }
            }
            modalInteractionDepth -= 1
            if modalInteractionDepth == 0 {
                // Activation notifications generated by dismissing an NSAlert
                // can arrive after runModal has already returned.
                modalDismissalGraceUntil = ProcessInfo.processInfo.systemUptime + 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.panel.isVisible, !self.isDismissing,
                          self.modalInteractionDepth == 0,
                          NSApp.modalWindow == nil else { return }
                    let focusWindow = self.detailPanel.flatMap { $0.isVisible ? $0 : nil } ?? self.panel
                    focusWindow.makeKeyAndOrderFront(nil)
                }
            }
        }
        return present()
    }

    init(model: AppController) {
        self.model = model
        panel = ShelfPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary
        ]
        panel.title = "剪贴板历史"
        panel.contentView = ShelfHostingView(rootView: ShelfView(model: model))

        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastExternalApplication = application
                guard self.panel.isVisible, !self.isDismissing,
                      !self.isModalInteractionActive else { return }
                // A delayed activation notification from the app that owned
                // the hotkey must not immediately undo the panel opening.
                let justOpened = ProcessInfo.processInfo.systemUptime - self.shownAtUptime < 0.35
                if justOpened && application.processIdentifier == self.previousApplication?.processIdentifier {
                    return
                }
                self.hide(restorePreviousApplication: false)
            }
        }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activatedForImagePreview,
                      self.panel.isVisible, !self.isDismissing,
                      !self.isModalInteractionActive else { return }
                let keyPanel = self.detailPanel.flatMap { $0.isVisible ? $0 : nil } ?? self.panel
                keyPanel.makeKeyAndOrderFront(nil)
#if DEBUG
                ImageGestureTrace.record("preview became active appActive=\(NSApp.isActive) panelKey=\(keyPanel.isKeyWindow) window=\(keyPanel.windowNumber)")
#endif
            }
        }
        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activatedForImagePreview,
                      self.panel.isVisible, !self.isDismissing,
                      !self.isModalInteractionActive else { return }
                // A click into another app can resign us before its global
                // mouse event arrives. Ignore keyboard screenshot focus changes.
                guard NSEvent.pressedMouseButtons & 0b11 != 0 else { return }
                self.dismissForOutsideClick(at: NSEvent.mouseLocation)
            }
        }
    }

    func show() {
        presentationGeneration += 1
        shownAtUptime = ProcessInfo.processInfo.systemUptime
        let showGeneration = presentationGeneration
        isDismissing = false
        activatedForImagePreview = false
        modalDismissalGraceUntil = 0
        clearDetailPanel(restoreShelfFocus: false)
        imagePreviewActivationToken = UUID()
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            previousApplication = lastExternalApplication
        } else {
            previousApplication = frontmost
            lastExternalApplication = frontmost
        }
        previousTarget = previousApplication.flatMap {
            PasteTargetSnapshot.capture(for: $0.processIdentifier)
        }

        let mouse = NSEvent.mouseLocation
        let opensOnMainScreen = UserDefaults.standard.string(forKey: "panelDisplayScreen") == "main"
        let primaryScreen = NSScreen.screens.first
        let screen = opensOnMainScreen
            ? primaryScreen
            : (NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? primaryScreen)
        guard let screen else { return }
        let bounds = screen.frame
        displayFrame = bounds
        currentPlacement = PanelPlacement(
            rawValue: UserDefaults.standard.string(forKey: "panelPlacement") ?? "bottom"
        ) ?? .bottom
        targetFrame = PanelLayout.frame(
            in: bounds,
            placement: currentPlacement,
            heightPreference: UserDefaults.standard.string(forKey: "panelHeight")
        )
        let startFrame = PanelLayout.offscreenFrame(from: targetFrame, placement: currentPlacement)
        SettingsWindowController.shared.prepareForPanelPresentation()
        tracePanel("before show")
        // Rebuild the hosting tree after ordering out. Otherwise AppKit may
        // reuse a scroll view whose gesture dispatch belonged to the previous
        // panel presentation.
        panel.contentView = ShelfHostingView(rootView: ShelfView(model: model))
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        tracePanel("after show")
        // A nonactivating panel can take keyboard focus without moving the
        // target app out of its fullscreen Space or raising Settings.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible, !self.isDismissing,
                  !self.isModalInteractionActive else { return }
            guard self.detailPanel?.isVisible != true else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            self.tracePanel("next turn")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.presentationGeneration == showGeneration,
                  self.panel.isVisible, !self.isDismissing,
                  !self.isModalInteractionActive else { return }
            if !self.panel.isOnActiveSpace {
                self.panel.orderFrontRegardless()
            }
            self.tracePanel("settled")
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.dismissForOutsideClick(at: clickLocation)
            }
        }
        settingsClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.isDismissing,
                      !self.isModalInteractionActive else { return }
                if SettingsWindowController.shared.contains(event.window) {
                    SettingsWindowController.shared.restoreForInteraction()
                    self.hide(restorePreviousApplication: false)
                } else if event.window === self.panel, let previewedID = self.previewedEntry?.id {
                    // Let the shelf handle this click first. Selecting a
                    // different card replaces the preview; clicking anywhere
                    // else on the shelf closes the existing preview.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.panel.isVisible, !self.isDismissing,
                              !self.isModalInteractionActive,
                              self.previewedEntry?.id == previewedID else { return }
                        self.detailCloseAction?()
                    }
                } else if event.window !== self.panel && event.window !== self.detailPanel {
                    // A click delivered locally to a different window can
                    // precede both Workspace activation and global monitoring.
                    self.dismissForOutsideClick(at: NSEvent.mouseLocation)
                }
            }
            return event
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, self.presentationGeneration == showGeneration,
                      !self.isDismissing, !self.isModalInteractionActive,
                      let panel, panel.isVisible else { return }
                guard self.detailPanel?.isVisible != true else { return }
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    private func dismissForOutsideClick(at location: CGPoint) {
        guard panel.isVisible, !isDismissing, !isModalInteractionActive,
              !panel.frame.contains(location),
              detailPanel.map({ $0.isVisible && $0.frame.contains(location) }) != true else { return }
        hide(restorePreviousApplication: false)
    }

    func activateForImagePreview() {
        guard panel.isVisible, !isDismissing else { return }
        guard !activatedForImagePreview else { return }
        // A nonactivating panel preserves the source app while browsing and
        // pasting. For pinch gestures, the user explicitly opened a preview:
        // make this app frontmost even if isActive still reports true while
        // the hotkey's source app retains the actual event stream.
        activatedForImagePreview = true
        imagePreviewActivationToken = UUID()
        let token = imagePreviewActivationToken
        ensureImagePreviewIsFrontmost()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.imagePreviewActivationToken == token else { return }
            self.ensureImagePreviewIsFrontmost()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.imagePreviewActivationToken == token else { return }
            self.ensureImagePreviewIsFrontmost()
        }
    }

    private var isCurrentApplicationFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier ==
            NSRunningApplication.current.processIdentifier
    }

    private func ensureImagePreviewIsFrontmost() {
        guard panel.isVisible, detailPanel?.isVisible == true,
              !isDismissing, !isModalInteractionActive else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        var activationSucceeded: Bool?
        if !isCurrentApplicationFrontmost {
            SettingsWindowController.shared.prepareForPanelPresentation()
            // This is a direct user request to inspect an image. The forced
            // activation is limited to that preview, so the source app does
            // not silently lose focus during ordinary history navigation.
            activationSucceeded = NSRunningApplication.current.activate()
        }
        let keyPanel = detailPanel ?? panel
        keyPanel.makeKeyAndOrderFront(nil)
#if DEBUG
        ImageGestureTrace.record("preview activate appActive=\(NSApp.isActive) frontmost=\(frontmost?.bundleIdentifier ?? "nil") frontmostPID=\(frontmost?.processIdentifier ?? -1) selfPID=\(NSRunningApplication.current.processIdentifier) policy=\(NSApp.activationPolicy().rawValue) activationSucceeded=\(activationSucceeded.map(String.init(describing:)) ?? "not-needed") panelKey=\(keyPanel.isKeyWindow) window=\(keyPanel.windowNumber)")
#endif
    }

#if DEBUG
    private func tracePanel(_ stage: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        ImageGestureTrace.record("panel \(stage) frontmost=\(frontmost?.bundleIdentifier ?? "nil") frontmostPID=\(frontmost?.processIdentifier ?? -1) policy=\(NSApp.activationPolicy().rawValue) settingsVisible=\(SettingsWindowController.shared.hasVisibleWindow) panelVisible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace) panelKey=\(panel.isKeyWindow) window=\(panel.windowNumber) frame=\(panel.frame)")
    }
#else
    private func tracePanel(_ stage: String) {}
#endif

    func updateLayoutIfVisible() {
        guard panel.isVisible else { return }
        let bounds = panel.screen?.frame ?? displayFrame
        guard !bounds.isEmpty else { return }
        displayFrame = bounds
        let placement = PanelPlacement(
            rawValue: UserDefaults.standard.string(forKey: "panelPlacement") ?? "bottom"
        ) ?? .bottom
        let nextFrame = PanelLayout.frame(
            in: bounds,
            placement: placement,
            heightPreference: UserDefaults.standard.string(forKey: "panelHeight")
        )
        guard nextFrame != targetFrame || placement != currentPlacement else { return }
        currentPlacement = placement
        targetFrame = nextFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(nextFrame, display: true)
            if let previewedEntry, let detailPanel, detailPanel.isVisible {
                let nextPreviewFrame = previewFrame(for: previewedEntry)
                updatePreviewTail(for: nextPreviewFrame, animated: true)
                detailPanel.animator().setFrame(
                    nextPreviewFrame, display: true
                )
            }
        }
    }

    func showDetail(
        _ entry: ClipboardEntry,
        cardFrame: CGRect?,
        onKeyDown: @escaping (NSEvent) -> Bool,
        onClose: @escaping () -> Void
    ) -> Bool {
        guard panel.isVisible, !isDismissing,
              PanelLayout.cardScreenFrame(
                shelfFrame: targetFrame, cardFrame: cardFrame
              ) != nil else { return false }
        let window: ShelfPanel
        if let detailPanel {
            window = detailPanel
        } else {
            window = ShelfPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isFloatingPanel = true
            window.level = .screenSaver
            window.becomesKeyOnlyIfNeeded = false
            window.hidesOnDeactivate = false
            window.isMovable = false
            window.collectionBehavior = [
                .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary
            ]
            window.title = "剪贴板预览"
            detailPanel = window
        }
        let wasVisible = window.isVisible
        let wasClosing = wasVisible && previewedEntry == nil
        let animateEntrance = (!wasVisible || wasClosing) &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        detailTransitionGeneration += 1
        let transitionGeneration = detailTransitionGeneration
        isDetailEntranceAnimating = animateEntrance
        previewMotion.progress = animateEntrance ? 0 : 1
        previewedEntry = entry
        detailCloseAction = onClose
        previewLocalCardFrame = cardFrame
        previewImagePixelSize = entry.isImagePreviewable
            ? model.imagePreviewPixelSize(for: entry) : nil
        previewTextPreferredSize = entry.kind == .text || entry.kind == .link
            ? PanelLayout.textPreviewPreferredSize(for: entry.text) : nil
        let frame = previewFrame(for: entry)
        updatePreviewTail(for: frame, animated: wasVisible && !wasClosing)
#if DEBUG
        ImageGestureTrace.record("preview show entry=\(entry.id) card=\(String(describing: cardFrame)) frame=\(frame)")
#endif
        window.contentView = DetailHostingView(rootView: DetailPreviewPanelView(
            model: model, entry: entry, onKeyDown: onKeyDown, onClose: onClose,
            backingScale: previewBackingScale,
            anchor: previewAnchor,
            motion: previewMotion
        ))
        if !wasVisible || wasClosing {
            window.alphaValue = 1
            window.setFrame(frame, display: false)
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.invalidateShadow()
        if wasVisible && !wasClosing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else if animateEntrance {
            // The tip already touches the selected card. Animate only the
            // bubble's scale; a parallel NSWindow frame animation makes the
            // preview appear to grow a second time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self, weak window] in
                guard let self, self.detailTransitionGeneration == transitionGeneration,
                      window?.isVisible == true else { return }
                window?.contentView?.layoutSubtreeIfNeeded()
                withAnimation(.easeOut(duration: 0.20), completionCriteria: .removed) {
                    self.previewMotion.progress = 1
                } completion: { [weak self, weak window] in
                    guard let self, self.detailTransitionGeneration == transitionGeneration else { return }
                    self.isDetailEntranceAnimating = false
                    window?.invalidateShadow()
                }
            }
        }
        if entry.isImagePreviewable { activateForImagePreview() }
        return true
    }

    func updateDetailAnchor(for entryID: UUID, cardFrame: CGRect?) {
        guard let previewedEntry, previewedEntry.id == entryID,
              let detailPanel, detailPanel.isVisible else { return }
        guard cardFrame != previewLocalCardFrame else { return }
        previewLocalCardFrame = cardFrame
        if isDetailEntranceAnimating { return }
        let frame = previewFrame(for: previewedEntry)
        updatePreviewTail(for: frame, animated: true)
#if DEBUG
        ImageGestureTrace.record("preview track entry=\(entryID) card=\(String(describing: cardFrame)) frame=\(frame)")
#endif
        guard abs(detailPanel.frame.minX - frame.minX) > 1 ||
                abs(detailPanel.frame.minY - frame.minY) > 1 ||
                abs(detailPanel.frame.width - frame.width) > 1 ||
                abs(detailPanel.frame.height - frame.height) > 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            detailPanel.animator().setFrame(frame, display: true)
        }
        detailPanel.invalidateShadow()
    }

    func refreshDetailLayout(for entry: ClipboardEntry) {
        guard previewedEntry?.id == entry.id,
              let detailPanel, detailPanel.isVisible else { return }
        previewedEntry = entry
        previewImagePixelSize = entry.isImagePreviewable
            ? model.imagePreviewPixelSize(for: entry) : nil
        let frame = previewFrame(for: entry)
        updatePreviewTail(for: frame, animated: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            detailPanel.animator().setFrame(frame, display: true)
        }
        detailPanel.invalidateShadow()
    }

    func hideDetail() {
        detailCloseAction = nil
        guard detailPanel?.isVisible == true, previewedEntry != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clearDetailPanel(restoreShelfFocus: true)
            return
        }
        detailTransitionGeneration += 1
        let transitionGeneration = detailTransitionGeneration
        isDetailEntranceAnimating = false
        previewedEntry = nil
        previewLocalCardFrame = nil
        previewImagePixelSize = nil
        previewTextPreferredSize = nil
        withAnimation(.easeInOut(duration: 0.15), completionCriteria: .removed) {
            previewMotion.progress = 0
        } completion: { [weak self] in
            guard let self, self.detailTransitionGeneration == transitionGeneration else { return }
            self.clearDetailPanel(restoreShelfFocus: true)
        }
    }

    private func clearDetailPanel(restoreShelfFocus: Bool) {
        detailTransitionGeneration += 1
        isDetailEntranceAnimating = false
        imagePreviewActivationToken = UUID()
        previewedEntry = nil
        detailCloseAction = nil
        previewLocalCardFrame = nil
        previewImagePixelSize = nil
        previewTextPreferredSize = nil
        detailPanel?.orderOut(nil)
        detailPanel?.contentView = NSView(frame: .zero)
        previewMotion.progress = 1
        if restoreShelfFocus && panel.isVisible && !isDismissing {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
    }

    private func previewFrame(for entry: ClipboardEntry) -> CGRect {
        let cardFrame = PanelLayout.cardScreenFrame(
            shelfFrame: targetFrame, cardFrame: previewLocalCardFrame
        )
        let preferredSize: CGSize
        if entry.isImagePreviewable {
            let availableSize = PanelLayout.detailPreviewAvailableSize(
                in: displayFrame, avoiding: targetFrame,
                placement: currentPlacement, cardFrame: cardFrame
            )
            preferredSize = PanelLayout.imagePreviewPreferredSize(
                pixelSize: previewImagePixelSize,
                backingScale: previewBackingScale,
                availableSize: availableSize,
                placement: currentPlacement,
                isFileReference: entry.kind == .fileReference
            )
        } else if entry.kind == .unavailableImage {
            preferredSize = CGSize(width: 480, height: 350)
        } else if entry.kind == .fileReference {
            preferredSize = CGSize(width: 860, height: 660)
        } else {
            preferredSize = previewTextPreferredSize
                ?? PanelLayout.textPreviewPreferredSize(for: entry.text)
        }
        return PanelLayout.detailPreviewFrame(
            in: displayFrame, avoiding: targetFrame,
            placement: currentPlacement, preferredSize: preferredSize, cardFrame: cardFrame
        )
    }

    private var previewBackingScale: CGFloat {
        panel.screen?.backingScaleFactor
            ?? NSScreen.screens.first(where: { $0.frame == displayFrame })?.backingScaleFactor
            ?? 1
    }

    private func updatePreviewTail(for previewFrame: CGRect, animated: Bool = false) {
        guard let cardFrame = PanelLayout.cardScreenFrame(
            shelfFrame: targetFrame, cardFrame: previewLocalCardFrame
        ) else { return }
        let tail = PanelLayout.previewTail(
            previewFrame: previewFrame, cardFrame: cardFrame, placement: currentPlacement
        )
        guard previewAnchor.tail != tail else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) { previewAnchor.tail = tail }
        } else {
            previewAnchor.tail = tail
        }
    }

    func hide(restorePreviousApplication: Bool = true, completion: (() -> Void)? = nil) {
        presentationGeneration += 1
        let hideGeneration = presentationGeneration
        isDismissing = true
        let shouldRestore = restorePreviousApplication && activatedForImagePreview
        activatedForImagePreview = false
        clearDetailPanel(restoreShelfFocus: false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let settingsClickMonitor {
            NSEvent.removeMonitor(settingsClickMonitor)
            self.settingsClickMonitor = nil
        }
        guard panel.isVisible else {
            if shouldRestore { restorePreviousApplicationIfNeeded() }
            SettingsWindowController.shared.restoreAfterPanelPresentation()
            completion?()
            return
        }
        let endFrame = PanelLayout.offscreenFrame(from: targetFrame, placement: currentPlacement)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard self?.presentationGeneration == hideGeneration else { return }
                panel?.orderOut(nil)
                if shouldRestore { self?.restorePreviousApplicationIfNeeded() }
                SettingsWindowController.shared.restoreAfterPanelPresentation()
                self?.tracePanel("after hide")
                completion?()
            }
        }
    }

    private func restorePreviousApplicationIfNeeded() {
        guard isCurrentApplicationFrontmost, let previousApplication,
              !previousApplication.isTerminated else { return }
        _ = previousApplication.activate()
    }
}
