import AppKit
import SwiftUI

private final class ClipboardTextEditorPanel: NSPanel, NSWindowDelegate, NSTextViewDelegate {
    private let editor = NSTextView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private let saveDraft: (String) throws -> Void
    private let instruction: String
    private var onClose: (() -> Void)?

    init(entry: ClipboardEntry, text: String, onSave: @escaping (String) throws -> Void,
         onClose: @escaping () -> Void) {
        saveDraft = onSave
        self.onClose = onClose
        instruction = entry.hasRichText
            ? "修改后按纯文本保存，原格式和附件将移除。"
            : "⌘↩ 保存 · Esc 取消"
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = entry.kind == .link ? "编辑链接" : "编辑文字"
        contentMinSize = NSSize(width: 400, height: 220)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        delegate = self

        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.font = entry.kind == .link || entry.textClassification.codeLanguage != nil
            ? .monospacedSystemFont(ofSize: 14, weight: .regular) : .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 8, height: 9)
        editor.textContainer?.widthTracksTextView = true
        editor.autoresizingMask = [.width]
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.setAccessibilityLabel("卡片原文")
        editor.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = editor
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        message.font = .systemFont(ofSize: 12)
        message.setContentHuggingPriority(.required, for: .vertical)
        showInstruction()
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelOperation(_:)))
        saveButton.title = entry.hasRichText ? "保存为纯文本" : "保存"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.toolTip = "⌘↩ 保存"
        saveButton.isEnabled = !text.isEmpty

        let actions = NSStackView(views: [cancel, saveButton])
        actions.spacing = 8
        let form = NSStackView(views: [scrollView, message, actions])
        form.orientation = .vertical
        form.alignment = .trailing
        form.spacing = 10
        form.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        contentView = form
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -36),
            message.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
        initialFirstResponder = editor
    }

    // A menu-bar app may have no Edit menu to deliver these key equivalents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard firstResponder === editor, !editor.hasMarkedText() else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command, .shift], key == "z" {
            editor.undoManager?.redo()
            return true
        }
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "a": editor.selectAll(nil)
        case "c": editor.copy(nil)
        case "v": editor.pasteAsPlainText(nil)
        case "x": editor.cut(nil)
        case "z": editor.undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        saveButton.isEnabled = !editor.string.isEmpty
        showInstruction()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)), !textView.hasMarkedText() else { return false }
        cancelOperation(nil)
        return true
    }

    private func showInstruction() {
        message.stringValue = instruction
        message.textColor = .secondaryLabelColor
    }

    @objc private func save() {
        guard onClose != nil, !editor.hasMarkedText() else { return }
        do {
            try saveDraft(editor.string)
            close()
        } catch {
            message.stringValue = "保存失败。\(error.localizedDescription)"
            message.textColor = .systemRed
            makeFirstResponder(editor)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        let completion = onClose
        onClose = nil
        completion?()
    }
}

final class ShelfPanelSurface: NSView {
    static let cornerRadius: CGFloat = 28

    private let backdrop: NSView
    private var shelfContent: NSView?

    override init(frame: NSRect) {
        let radius = Self.cornerRadius
        let backdropFrame = NSRect(origin: .zero, size: frame.size)
        if #available(macOS 26.0, *) {
            // Keep the regular glass behind the card and hover views so their
            // updates do not rebuild the material or change its tint.
            let glass = NSGlassEffectView(frame: backdropFrame)
            glass.style = .regular
            glass.cornerRadius = radius
            if #available(macOS 27.0, *) { glass.effectIsInteractive = false }
            let glassContent = NSView(frame: glass.bounds)
            glassContent.autoresizingMask = [.width, .height]
            glass.contentView = glassContent
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: backdropFrame)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            let side = 2 * radius + 1
            let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            effect.maskImage = mask
            backdrop = effect
        }
        super.init(frame: frame)
        // Clip the native material and hosting view together. Their individual
        // rounded corners do not clip sibling layers at the window's corners.
        wantsLayer = true
        clipsToBounds = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { nil }

    func setShelfContent(_ view: NSView) {
        shelfContent?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .above, relativeTo: backdrop)
        shelfContent = view
    }
}

private final class ShelfHostingView: NSHostingView<ShelfView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(ClipboardInternalDrag.destinationTypes)
    }

    // Reject native drops over the shelf so they cannot reach the app behind it.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
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
final class PreviewBubbleAnchor: ObservableObject {
    @Published var tail = PreviewTail(edge: .bottom, offset: 60)
}

@MainActor
final class PreviewBubbleMotion: ObservableObject {
    @Published var progress: CGFloat = 1
}

struct ClipboardPreviewSurface<Content: View>: View {
    let tail: PreviewTail
    let progress: CGFloat
    let onKeyDown: (NSEvent) -> Bool
    let content: Content

    init(tail: PreviewTail, progress: CGFloat = 1, onKeyDown: @escaping (NSEvent) -> Bool,
         @ViewBuilder content: () -> Content) {
        self.tail = tail
        self.progress = progress
        self.onKeyDown = onKeyDown
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, tail.edge == .top ? 10 : 0)
                .padding(.bottom, tail.edge == .bottom ? 10 : 0)
                .padding(.leading, tail.edge == .left ? 10 : 0)
                .padding(.trailing, tail.edge == .right ? 10 : 0)
                .background(.regularMaterial, in: PreviewBubbleShape(tail: tail))
                .clipShape(PreviewBubbleShape(tail: tail))
                .overlay {
                    PreviewBubbleShape(tail: tail)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .scaleEffect(0.025 + 0.975 * progress,
                             anchor: expansionAnchor(in: geometry.size))
                .opacity(min(1, progress * 12))
                .background {
                    ShelfKeyMonitor(onKeyDown: onKeyDown)
                        .frame(width: 0, height: 0)
                }
        }
    }

    private func expansionAnchor(in size: CGSize) -> UnitPoint {
        let horizontal = min(1, max(0, tail.offset / max(1, size.width)))
        let vertical = min(1, max(0, tail.offset / max(1, size.height)))
        switch tail.edge {
        case .bottom: return UnitPoint(x: horizontal, y: 1)
        case .top: return UnitPoint(x: horizontal, y: 0)
        case .left: return UnitPoint(x: 0, y: vertical)
        case .right: return UnitPoint(x: 1, y: vertical)
        }
    }
}

struct DetailPreviewPanelView: View {
    @ObservedObject var model: AppController
    let entry: ClipboardEntry
    let initiallyShowsOCR: Bool
    let initiallyShowsTools: Bool
    let onKeyDown: (NSEvent) -> Bool
    let onClose: () -> Void
    let onPopoverVisibilityChange: (Bool) -> Void
    let backingScale: CGFloat
    @ObservedObject var anchor: PreviewBubbleAnchor
    @ObservedObject var motion: PreviewBubbleMotion
    var onBeforeSeparateAction: (() -> Void)? = nil
    var onPreviewImageAppear: (() -> Void)? = nil
    var onCopyOverride: (() -> Void)? = nil

    private func separateAction(_ action: () -> Void) {
        onBeforeSeparateAction?()
        action()
    }

    var body: some View {
        let currentEntry = model.entries.first(where: { $0.id == entry.id })
            ?? model.entries.lazy.filter { $0.kind == .group }
                .flatMap(\.groupMembers).first(where: { $0.id == entry.id })
            ?? entry
        ClipboardPreviewSurface(tail: anchor.tail, progress: motion.progress, onKeyDown: onKeyDown) {
        ClipboardDetailView(
            entry: currentEntry,
            backingScale: backingScale,
            imageURL: model.imageURL(for: currentEntry),
            thumbnailURL: model.thumbnailURL(for: currentEntry),
            richTextFiles: model.richTextSourceFiles(for: currentEntry),
            fileHasSavedCopy: model.fileHasSavedCopy(currentEntry),
            savedCopyName: model.savedCopyDisplayName(for: currentEntry),
            fileReferenceAvailable: model.fileReferenceCanBeRepublished(currentEntry),
            originalFileReferenceAvailable: model.originalFileReferenceIsAvailable(currentEntry),
            canAuthorizeWeChatFolder: model.canAuthorizeWeChatFolder(currentEntry),
            loadFileReferenceImage: { await model.fileReferencePreviewImage(for: currentEntry) },
            makeFilePreviewAccess: { model.filePreviewAccess(for: currentEntry) },
            onCopy: { if let onCopyOverride { onCopyOverride() } else { model.copy(currentEntry) } },
            onSaveImageToFile: { separateAction { model.saveImageToFile(currentEntry) } },
            canRecognize: model.canRecognizeImage(currentEntry),
            isRecognizing: model.imageOCRInProgress.contains(currentEntry.id),
            initiallyShowsOCR: initiallyShowsOCR,
            initiallyShowsTools: initiallyShowsTools,
            shortcuts: model.shortcuts,
            previewActionRequest: model.previewActionRequest,
            ocrError: model.imageOCRErrors[currentEntry.id],
            onRecognize: { model.recognizeImageText(currentEntry) },
            onCopyOCRText: { model.copyRecognizedText($0) },
            onCopyTranslatedText: { model.copyTranslatedText($0) },
            onCopyProcessedText: { model.copyProcessedText($0) },
            canAnnotateScreenshot: model.canAnnotateScreenshot(currentEntry),
            onAnnotateScreenshot: { separateAction { model.annotateScreenshot(currentEntry) } },
            canPin: model.canPinImage(currentEntry),
            isPinned: model.isPinnedImage(currentEntry),
            onPin: { onBeforeSeparateAction?(); return model.pinImage(currentEntry) },
            onUnpin: { model.unpinImage(currentEntry) },
            onRevealOriginalFile: { onBeforeSeparateAction?(); return model.revealOriginalFile(currentEntry) },
            onRelinkFile: { separateAction { model.relinkUnavailableFile(currentEntry) } },
            onAuthorizeWeChatFolder: { separateAction { model.authorizeWeChatFolder(for: currentEntry) } },
            onSaveFileCopy: { separateAction { model.saveFileCopy(currentEntry) } },
            onRemoveFileCopy: { separateAction { model.removeSavedFileCopy(currentEntry) } },
            onEditText: { separateAction { model.editText(currentEntry) } },
            onDelete: { separateAction { model.confirmDelete(currentEntry) } },
            onImagePreviewAppear: { if let onPreviewImageAppear { onPreviewImageAppear() } else { model.activatePanelForImagePreview() } },
            onPopoverVisibilityChange: onPopoverVisibilityChange,
            onClose: onClose
        )
        .id("\(entry.id.uuidString)-\(model.panelPresentationID.uuidString)")
        }
    }
}

private final class DetailHostingView: NSHostingView<DetailPreviewPanelView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController {
    private let panel: ShelfPanel
    private let shelfSurface = ShelfPanelSurface(frame: .zero)
    private var detailPanel: ShelfPanel?
    private var previewedEntry: ClipboardEntry?
    private var detailPopoverVisible = false
    private var shelfHeaderPopoverVisible = false
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
    private var isExternalDragActive = false
    private var cardDragState = PanelCardDragState()
    private var dragCancellationGraceUntil: TimeInterval = 0
    private var activatedForImagePreview = false
    private var imagePreviewActivationToken = UUID()
    private var modalInteractionDepth = 0
    private var textEditor: ClipboardTextEditorPanel?
    private var screenshotInteractionLevels: (shelf: NSWindow.Level, preview: NSWindow.Level?)?
    private var modalDismissalGraceUntil: TimeInterval = 0
    private var presentationGeneration = 0
    private var shownAtUptime: TimeInterval = 0

    var isVisible: Bool { panel.isVisible }
    var isEditingText: Bool { textEditor != nil }
    var isCardDragActive: Bool { isExternalDragActive || panel.localCardDragSource != nil }

    func suspendForQuickSearch() -> Bool {
        guard panel.isVisible, !isDismissing, !isCardDragActive else { return false }
        presentationGeneration += 1
        imagePreviewActivationToken = UUID()
        detailCloseAction?()
        clearDetailPanel(restoreShelfFocus: false)
        panel.orderOut(nil)
        return true
    }

    func resumeAfterQuickSearch() {
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    private var isModalInteractionActive: Bool {
        modalInteractionDepth > 0 || screenshotInteractionLevels != nil
            || NSApp.modalWindow != nil ||
            ProcessInfo.processInfo.systemUptime < modalDismissalGraceUntil
    }

    func beginScreenshotInteraction() {
        guard panel.isVisible || isEditingText, screenshotInteractionLevels == nil else { return }
        let preview = detailPanel.flatMap { $0.isVisible ? $0 : nil }
        screenshotInteractionLevels = (panel.level, preview?.level)
        // Leave the shelf visible, but let the screenshot selector receive
        // pointer events above it. Suppress the shelf's focus-loss dismissal.
        panel.level = NSWindow.Level(rawValue: PanelLayout.screenshotBackgroundWindowLevel(for: panel.level.rawValue))
        if let preview {
            preview.level = NSWindow.Level(rawValue: PanelLayout.screenshotBackgroundWindowLevel(for: preview.level.rawValue))
        }
    }

    func endScreenshotInteraction() {
        guard let levels = screenshotInteractionLevels else { return }
        screenshotInteractionLevels = nil
        panel.level = levels.shelf
        if let previewLevel = levels.preview,
           let preview = detailPanel, preview.isVisible {
            preview.level = previewLevel
        }
        // The screenshot window finishes closing after its callback. Restore
        // the same editor next turn without replacing its draft or selection.
        if let editor = textEditor {
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor, self.textEditor === editor,
                      editor.isVisible, self.screenshotInteractionLevels == nil,
                      NSApp.modalWindow == nil else { return }
                editor.makeKeyAndOrderFront(nil)
            }
        }
    }

    func performModalInteraction<T>(_ present: () -> T) -> T {
        let finish = beginPanelInteraction()
        defer { finish() }
        return present()
    }

    /// Protect the shelf and lower it for either a modal chooser or the
    /// modeless text editor. The latter keeps this lease until it closes.
    private func beginPanelInteraction() -> () -> Void {
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
        return { [weak self] in
            guard let self else { return }
            if hadVisibleShelf {
                self.panel.isFloatingPanel = originalShelfFloating
                self.panel.level = originalShelfLevel
                if let visiblePreview, let originalPreviewFloating, let originalPreviewLevel {
                    visiblePreview.isFloatingPanel = originalPreviewFloating
                    visiblePreview.level = originalPreviewLevel
                }
            }
            self.modalInteractionDepth -= 1
            if self.modalInteractionDepth == 0 {
                // Activation notifications generated by dismissing an NSAlert
                // can arrive after runModal has already returned.
                self.modalDismissalGraceUntil = ProcessInfo.processInfo.systemUptime + 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.panel.isVisible, !self.isDismissing,
                          self.modalInteractionDepth == 0,
                          self.screenshotInteractionLevels == nil,
                          NSApp.modalWindow == nil else { return }
                    let focusWindow = self.detailPanel.flatMap { $0.isVisible ? $0 : nil } ?? self.panel
                    focusWindow.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    @discardableResult
    func presentTextEditor(for entry: ClipboardEntry, text: String,
                           onClose: (() -> Void)? = nil,
                           onSave: @escaping (String) throws -> Void) -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        if let textEditor {
            textEditor.makeKeyAndOrderFront(nil)
            return false
        }
        guard !isModalInteractionActive else { return false }
        let finish = beginPanelInteraction()
        let editor = ClipboardTextEditorPanel(entry: entry, text: text, onSave: onSave) { [weak self] in
            self?.textEditor = nil
            finish()
            onClose?()
        }
        textEditor = editor
        if let screen = panel.screen ?? NSScreen.main {
            let area = screen.visibleFrame
            let origin = NSPoint(x: area.midX - editor.frame.width / 2,
                                 y: area.midY - editor.frame.height / 2)
            editor.setFrameOrigin(origin)
        }
        editor.makeKeyAndOrderFront(nil)
        return true
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
        panel.level = NSWindow.Level(rawValue: PanelLayout.shelfWindowLevel)
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary
        ]
        panel.title = "剪贴板历史"
        panel.contentView = shelfSurface
        shelfSurface.setShelfContent(ShelfHostingView(rootView: ShelfView(model: model)))

        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != NSRunningApplication.current.processIdentifier {
            lastExternalApplication = frontmost
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastExternalApplication = application
                guard self.panel.isVisible, !self.isDismissing,
                      !self.isModalInteractionActive,
                      !self.isCardDragActive,
                      ProcessInfo.processInfo.systemUptime >= self.dragCancellationGraceUntil else { return }
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
                      !self.isModalInteractionActive,
                      !self.isCardDragActive else { return }
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
        _ = cancelLocalCardDrag()
        shelfHeaderPopoverVisible = false
        presentationGeneration += 1
        shownAtUptime = ProcessInfo.processInfo.systemUptime
        let showGeneration = presentationGeneration
        isDismissing = false
        isExternalDragActive = false
        cardDragState.reset()
        dragCancellationGraceUntil = 0
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        activatedForImagePreview = false
        modalDismissalGraceUntil = 0
        clearDetailPanel(restoreShelfFocus: false)
        imagePreviewActivationToken = UUID()
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier == NSRunningApplication.current.processIdentifier {
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
        shelfSurface.setShelfContent(ShelfHostingView(rootView: ShelfView(model: model)))
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        tracePanel("after show")
        // A nonactivating panel can take keyboard focus without moving the
        // target app out of its fullscreen Space or raising Settings.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible, !self.isDismissing,
                  !self.isModalInteractionActive, !self.isCardDragActive else { return }
            guard self.detailPanel?.isVisible != true else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            self.tracePanel("next turn")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.presentationGeneration == showGeneration,
                  self.panel.isVisible, !self.isDismissing,
                  !self.isModalInteractionActive, !self.isCardDragActive else { return }
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
                }
                // SwiftUI popovers (including Text Tools and Translate) use
                // their own app window. A local mouse event still belongs to
                // ClipHoook, so it must reach the popover's button before any
                // shelf dismissal. Clicks into other apps are handled by the
                // global monitor and activation observer instead.
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
                      !self.isCardDragActive,
                      let panel, panel.isVisible else { return }
                guard self.detailPanel?.isVisible != true else { return }
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    private func dismissForOutsideClick(at location: CGPoint) {
        guard panel.isVisible, !isDismissing, !isModalInteractionActive,
              !isCardDragActive,
              ProcessInfo.processInfo.systemUptime >= dragCancellationGraceUntil,
              !panel.frame.contains(location),
              detailPanel.map({ $0.isVisible && $0.frame.contains(location) }) != true,
              !((detailPopoverVisible || shelfHeaderPopoverVisible) && isOwnPopup(at: location)) else { return }
        hide(restorePreviousApplication: false)
    }

    func setShelfHeaderPopoverVisible(_ visible: Bool) {
        shelfHeaderPopoverVisible = visible
    }

    private func isOwnPopup(at location: CGPoint) -> Bool {
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(location) }) {
            return true
        }
        // A SwiftUI Menu can be hosted in an auxiliary AppKit window outside
        // the shelf's frame. Global mouse monitoring may see that click as an
        // outside click even though the menu belongs to ClipHoook.
        guard let mainScreenTop = NSScreen.screens.first?.frame.maxY else { return false }
        let displayPoint = CGPoint(x: location.x, y: mainScreenTop - location.y)
        let visible = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        for item in visible {
            guard let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(displayPoint) else { continue }
            let pid = item[kCGWindowOwnerPID as String] as? NSNumber
            return pid?.int32Value == ProcessInfo.processInfo.processIdentifier
        }
        return false
    }

    func cancelLocalCardDrag() -> Bool {
        panel.localCardDragSource?.cancelLocalCardDrag() ?? false
    }

    func beginExternalDrag() {
        guard panel.isVisible, !isDismissing else { return }
        isExternalDragActive = true
        dragCancellationGraceUntil = 0
        cardDragState.begin(in: panel.frame)
    }

    func updateExternalDrag(at point: NSPoint) {
        guard isExternalDragActive, cardDragState.moved(to: point) else { return }
        // Keep the source view alive for AppKit's drag session while uncovering
        // the destination beneath this high-level panel. Use the same exit
        // movement as a normal dismissal, but leave the window ordered in.
        panel.ignoresMouseEvents = true
        detailPanel?.ignoresMouseEvents = true
        let endFrame = PanelLayout.offscreenFrame(from: targetFrame, placement: currentPlacement)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
            detailPanel?.animator().alphaValue = 0
        }
    }

    func finishExternalDrag(didDrop: Bool) {
        guard isExternalDragActive else { return }
        if cardDragState.shouldHideAfterDrop(succeeded: didDrop) {
            cardDragState.reset()
            hide(restorePreviousApplication: false)
        } else {
            // Activation notifications from the target can arrive after the
            // drag callback. Keep them from closing the restored shelf.
            dragCancellationGraceUntil = ProcessInfo.processInfo.systemUptime + 0.35
            panel.ignoresMouseEvents = false
            detailPanel?.ignoresMouseEvents = false
            if cardDragState.hasLeftPanel {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(targetFrame, display: true)
                    detailPanel?.animator().alphaValue = 1
                }
            }
            let focusPanel = detailPanel.flatMap { $0.isVisible ? $0 : nil } ?? panel
            if cardDragState.hasLeftPanel || !focusPanel.isKeyWindow {
                focusPanel.makeKeyAndOrderFront(nil)
                focusPanel.orderFrontRegardless()
            }
        }
        isExternalDragActive = false
        cardDragState.reset()
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

    func activateForPinnedImageInteraction() {
        guard panel.isVisible, !isDismissing, !isModalInteractionActive else { return }
        if !isCurrentApplicationFrontmost {
            SettingsWindowController.shared.prepareForPanelPresentation()
            _ = NSRunningApplication.current.activate()
        }
        let keyPanel = detailPanel.flatMap { $0.isVisible ? $0 : nil } ?? panel
        keyPanel.makeKeyAndOrderFront(nil)
#if DEBUG
        ImageGestureTrace.record("pin activate appActive=\(NSApp.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") panelKey=\(keyPanel.isKeyWindow) window=\(keyPanel.windowNumber)")
#endif
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
        initiallyShowsOCR: Bool,
        initiallyShowsTools: Bool,
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
            window.level = NSWindow.Level(rawValue: PanelLayout.shelfWindowLevel)
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
            model: model, entry: entry, initiallyShowsOCR: initiallyShowsOCR,
            initiallyShowsTools: initiallyShowsTools,
            onKeyDown: onKeyDown, onClose: onClose,
            onPopoverVisibilityChange: { [weak self] visible in
                self?.detailPopoverVisible = visible
            },
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
        if entry.kind.isTextual {
            previewTextPreferredSize = PanelLayout.textPreviewPreferredSize(for: entry.text)
        }
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
        detailPopoverVisible = false
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
        detailPopoverVisible = false
        detailCloseAction = nil
        previewLocalCardFrame = nil
        previewImagePixelSize = nil
        previewTextPreferredSize = nil
        detailPanel?.orderOut(nil)
        detailPanel?.alphaValue = 1
        detailPanel?.ignoresMouseEvents = false
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

    func hideForPaste(reclaimingPinKey: Bool, completion: @escaping (Bool) -> Void) {
        // Order-out gives up the key state. If a pin currently has it, move
        // it to the shelf first so the pin doesn't need to be hidden.
        if reclaimingPinKey && panel.isVisible { panel.makeKey() }
        hide(restorePreviousApplication: false, onInterrupted: { completion(false) }) {
            completion(true)
        }
    }

    func hide(restorePreviousApplication: Bool = true, completion: (() -> Void)? = nil) {
        hide(restorePreviousApplication: restorePreviousApplication, onInterrupted: nil, completion: completion)
    }

    private func hide(
        restorePreviousApplication: Bool,
        onInterrupted: (() -> Void)?,
        completion: (() -> Void)?
    ) {
        presentationGeneration += 1
        let hideGeneration = presentationGeneration
        isDismissing = true
        _ = cancelLocalCardDrag()
        model.setImageTextSearchScope(nil)
        isExternalDragActive = false
        cardDragState.reset()
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
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
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
                guard self?.presentationGeneration == hideGeneration else {
                    onInterrupted?()
                    return
                }
                panel?.orderOut(nil)
                panel?.alphaValue = 1
                panel?.ignoresMouseEvents = false
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

/// A brief, nonactivating explanation shown after the shelf returns focus to
/// the original app. The shelf footer and menu bar keep the same message.
private final class PasteFallbackPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PasteFallbackPanelController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(message: String, onOpenSettings: (() -> Void)?) {
        dismissTask?.cancel()
        let height: CGFloat = onOpenSettings == nil ? 116 : 148
        let size = NSSize(width: 370, height: height)
        let panel = panel ?? PasteFallbackPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PasteFallbackNoticeView(
            message: message,
            openSettings: onOpenSettings,
            dismiss: { [weak self] in self?.dismiss() }
        ))
        panel.setContentSize(size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 18,
                y: visible.maxY - size.height - 18
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
    }
}

private struct PasteFallbackNoticeView: View {
    let message: String
    let openSettings: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("自动粘贴未完成")
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if let openSettings {
                Button("打开键盘事件权限设置") {
                    dismiss()
                    openSettings()
                }
                    .font(.subheadline)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .padding(8)
    }
}
