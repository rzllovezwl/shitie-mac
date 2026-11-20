import AppKit
import Carbon
import Combine
import ImageIO
import SwiftUI

private final class QuickSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class QuickSearchHostingView: NSHostingView<QuickSearchView> {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class QuickSearchController: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch(preserveSelection: false) } } }
    @Published private(set) var results: [ClipboardQuickSearchResult] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isMatching = false
    @Published private(set) var message: String?
    private(set) var isPresented = false
    private let model: AppController
    private var panel: QuickSearchPanel?
    private var previewPanel: QuickSearchPanel?
    private var previewID: UUID?
    private var previewPopoverVisible = false
    private weak var searchField: NSSearchField?
    private var entries: [ClipboardEntry] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var presentationGeneration = UUID()
    private var entriesSubscription: AnyCancellable?
    private var keyboardMonitor: Any?
    private var outsideMonitor: Any?
    private var localClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var application: NSRunningApplication?
    private var target: PasteTargetSnapshot?
    private var screen: NSScreen?
    private var onDismiss: ((Bool) -> Void)?
    private let thumbnails = NSCache<NSString, NSImage>()

    init(model: AppController) {
        self.model = model
        thumbnails.totalCostLimit = 8 * 1_024 * 1_024
        entriesSubscription = model.$entries.sink { [weak self] entries in
            guard let self, self.isPresented else { return }
            self.entries = entries
            self.scheduleSearch(preserveSelection: true)
        }
    }

    func show(application: NSRunningApplication?, target: PasteTargetSnapshot?, onDismiss: @escaping (Bool) -> Void) {
        guard !isPresented else { focusSearch(); return }
        self.application = application
        self.target = target
        self.onDismiss = onDismiss
        entries = model.entries
        screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        presentationGeneration = UUID()
        isPresented = true
        message = nil
        query = ""
        results = ClipboardQuickSearch.results(in: entries, query: "")
        selectedID = results.first?.id
        if panel == nil {
            let window = makePanel(title: "搜索剪贴板历史")
            let surface = ShelfPanelSurface(frame: .zero)
            surface.setShelfContent(QuickSearchHostingView(rootView: QuickSearchView(controller: self, model: model)))
            window.contentView = surface
            panel = window
        }
        resize(animated: false)
        installMonitors()
        panel?.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.13
            panel?.animator().alphaValue = 1
        }
        focusSearch()
        let generation = presentationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, self.presentationGeneration == generation else { return }
            self.focusSearch()
        }
    }

    func dismiss(restore: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        presentationGeneration = UUID()
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        isMatching = false
        closePreview(restoreSearch: false)
        panel?.orderOut(nil)
        removeMonitors()
        model.setImageTextSearchScope(nil)
        let finish = onDismiss
        onDismiss = nil
        finish?(restore)
    }

    func attach(_ field: NSSearchField) { searchField = field }

    func focusSearch() {
        guard isPresented, previewID == nil else { return }
        panel?.makeKeyAndOrderFront(nil)
        if let searchField { panel?.makeFirstResponder(searchField) }
    }

    func select(_ id: UUID) { selectedID = id }

    func pasteSelected() {
        guard !isMatching, let entry = selectedEntry() else { return }
        let context = QuickSearchPasteContext(application: application, target: target) { [weak self] completion in
            self?.dismiss(restore: false)
            completion(true)
        }
        model.pasteFromQuickSearch(entry, context: context)
        if isPresented { message = model.statusMessage }
    }

    func copySelected(plain: Bool = false) {
        guard !isMatching, let entry = selectedEntry() else { return }
        dismiss(restore: true)
        plain ? model.copyPlainText(entry) : model.copy(entry)
    }

    private func selectedEntry() -> ClipboardEntry? {
        guard let selectedID, let entry = model.currentHistoryEntry(selectedID) else {
            message = "这条记录已删除或过期，请重新选择。"
            return nil
        }
        return entry
    }

    private func scheduleSearch(preserveSelection: Bool) {
        guard isPresented else { return }
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        let phrase = query, snapshot = entries
        let previous = selectedID
        isMatching = true
        message = nil
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                ClipboardQuickSearch.results(in: snapshot, query: phrase)
            }
            let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.isPresented, self.searchGeneration == generation else { return }
            self.results = found
            self.selectedID = ClipboardQuickSearch.selection(after: found, previous: previous, preserve: preserveSelection)
            self.isMatching = false
            if let previewID = self.previewID, self.model.currentHistoryEntry(previewID) == nil {
                self.closePreview()
                self.message = "预览的记录已删除或过期。"
            }
            self.resize(animated: true)
            let scope = ClipboardQuickSearch.terms(in: phrase).isEmpty ? nil
                : ClipboardImageSearchScope(filter: .all, date: nil, tab: .history)
            self.model.setImageTextSearchScope(scope)
            if scope != nil { self.model.resumeImageTextSearchIfNeeded() }
        }
    }

    private func resize(animated: Bool) {
        guard let panel, let screen else { return }
        let area = screen.visibleFrame.insetBy(dx: 18, dy: 18)
        let width = min(680, area.width)
        let rows = min(8, max(1, results.count))
        let height = min(area.height, results.isEmpty ? 206 : CGFloat(rows) * 54 + 114)
        let top = area.maxY - min(135, max(16, area.height * 0.15))
        let frame = CGRect(x: area.midX - width / 2, y: max(area.minY, top - height), width: width, height: height)
        guard panel.frame != frame else { return }
        if animated, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: false) }
        panel.invalidateShadow()
    }

    private func makePanel(title: String) -> QuickSearchPanel {
        let window = QuickSearchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        window.title = title
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: PanelLayout.shelfWindowLevel + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return window
    }

    func togglePreview() {
        guard previewID == nil else { closePreview(); return }
        guard !isMatching, let entry = selectedEntry(), let screen else { return }
        let window = previewPanel ?? makePanel(title: "剪贴板预览")
        previewPanel = window
        previewID = entry.id
        let area = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        let size = CGSize(width: min(900, area.width), height: min(760, area.height))
        window.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: false)
        window.contentView = NSHostingView(rootView: DetailPreviewPanelView(
            model: model, entry: entry, initiallyShowsOCR: false, initiallyShowsTools: false,
            onKeyDown: { _ in false }, onClose: { [weak self] in self?.closePreview() },
            onPopoverVisibilityChange: { [weak self] in self?.previewPopoverVisible = $0 },
            backingScale: screen.backingScaleFactor,
            anchor: PreviewBubbleAnchor(), motion: PreviewBubbleMotion(),
            onBeforeSeparateAction: { [weak self] in self?.dismiss(restore: false) },
            onPreviewImageAppear: {},
            onCopyOverride: { [weak self] in self?.copySelected() }
        ))
        panel?.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.invalidateShadow()
    }

    func closePreview(restoreSearch: Bool = true) {
        guard previewID != nil else { return }
        previewID = nil
        previewPopoverVisible = false
        previewPanel?.orderOut(nil)
        previewPanel?.contentView = nil
        if restoreSearch, isPresented { panel?.orderFrontRegardless(); focusSearch() }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented, NSApp.modalWindow == nil,
              event.window === panel || event.window === previewPanel else { return false }
        if previewPopoverVisible { return false }
        let editor = event.window?.firstResponder as? NSTextView
        if previewID != nil, let editor, editor.selectedRange().length > 0,
           event.keyCode == UInt16(kVK_ANSI_C),
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            let selected = editor.selectedRange()
            let content = editor.string as NSString
            if NSMaxRange(selected) <= content.length {
                model.copySelectedPreviewText(content.substring(with: selected))
                return true
            }
        }
        let inputFocused = editor?.isFieldEditor == true || editor?.isEditable == true
        guard let action = QuickSearchKeyAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
            inputFocused: inputFocused, hasMarkedText: editor?.hasMarkedText() == true) else { return false }
        switch action {
        case .dismiss:
            if previewID != nil { closePreview() } else { dismiss() }
        case .preview: togglePreview()
        case .paste: if !event.isARepeat { pasteSelected() }
        case .copy: copySelected()
        case .copyPlainText: copySelected(plain: true)
        case .focusSearch:
            if previewID != nil { closePreview() }
            focusSearch()
        case .switchFocus:
            if previewID != nil { return false }
            if inputFocused { panel?.makeFirstResponder(panel?.contentView) } else { focusSearch() }
        case .previous, .next:
            if previewID != nil { return false }
            selectedID = ClipboardQuickSearch.moving(selectedID, by: action == .previous ? -1 : 1, in: results)
        }
        return true
    }

    private func installMonitors() {
        removeMonitors()
        let generation = presentationGeneration
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.presentationGeneration == generation else { return }
                self.dismiss(restore: false)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isPresented, NSApp.modalWindow == nil,
                      event.window !== self.panel, event.window !== self.previewPanel,
                      !self.previewPopoverVisible else { return }
                // SwiftUI menus/popovers have their own windows. Only known
                // ordinary app windows are outside; transient panels keep focus.
                if event.window?.styleMask.contains(.titled) == true { self.dismiss(restore: false) }
            }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
            Task { @MainActor in
                guard let self, self.presentationGeneration == generation,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                self.dismiss(restore: false)
            }
        }
    }

    private func removeMonitors() {
        for monitor in [keyboardMonitor, outsideMonitor, localClickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyboardMonitor = nil; outsideMonitor = nil; localClickMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func thumbnail(for entry: ClipboardEntry) async -> NSImage? {
        let key = "\(entry.id)-\(entry.digest)" as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        guard let url = model.thumbnailURL(for: entry) ?? (entry.kind == .image ? model.imageURL(for: entry) : nil) else { return nil }
        let bitmap = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 96
            ] as CFDictionary)
        }.value
        guard !Task.isCancelled, let bitmap else { return nil }
        let image = NSImage(cgImage: bitmap, size: CGSize(width: bitmap.width, height: bitmap.height))
        thumbnails.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.height)
        return image
    }
}
