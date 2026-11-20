import AppKit
import Carbon
import SwiftUI

enum ShelfKeyboardAction: Equatable {
    case previous
    case next
    case paste
    case pastePlainText
    case copyOnly
    case copyPlainText
    case groupSelection
    case ungroupSelection
    case togglePinImage
    case recognizeImageText
    case annotateImage
    case editText
    case saveImageToFile
    case toggleFavorite
    case toggleShelfPin
    case translate
    case toggleDetail
    case dismiss
    case focusSearch
    case deleteSelected

    static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        searchFocused: Bool,
        searchIsEmpty: Bool,
        textEditingAvailable: Bool = false,
        shortcuts: [AppShortcutAction: AppShortcut] = [:]
    ) -> ShelfKeyboardAction? {
        let held = modifiers.intersection([.command, .control, .option, .shift])
        if keyCode == UInt16(kVK_Escape), held.isEmpty { return .dismiss }
        for action in AppShortcutAction.allCases where !action.isGlobal && !action.isAnnotationTool {
            let shortcut = shortcuts[action] ?? action.defaultShortcut
            guard shortcut.matches(keyCode: keyCode, modifiers: held) else { continue }
            if searchFocused, [.copyOnly, .copyPlainText, .groupSelection,
                               .ungroupSelection, .togglePinImage,
                               .recognizeImageText, .annotateImage, .toggleFavorite, .toggleShelfPin,
                               .translateScreenshot].contains(action) {
                return nil
            }
            if (action == .previous || action == .next),
               searchFocused, !searchIsEmpty, held.isEmpty,
               (keyCode == UInt16(kVK_LeftArrow) || keyCode == UInt16(kVK_RightArrow)) {
                return nil
            }
            switch action {
            case .openPanel, .quickSearch, .recordScreen, .pauseScreenRecording, .captureRegion, .captureScreen, .captureLongScreenshot,
                 .captureTranslate, .captureRecognizeText: break
            case .translateScreenshot: return .translate
            case .annotateImage: return textEditingAvailable ? .editText : .annotateImage
            case .saveImageToFile: return .saveImageToFile
            case .toggleFavorite: return .toggleFavorite
            case .toggleShelfPin: return .toggleShelfPin
            case .deleteEntry: return .deleteSelected
            case .focusSearch: return .focusSearch
            case .previous: return .previous
            case .next: return .next
            case .toggleDetail: return searchFocused && held.isEmpty ? nil : .toggleDetail
            case .paste: return .paste
            case .pastePlainText: return .pastePlainText
            case .copyOnly: return .copyOnly
            case .copyPlainText: return .copyPlainText
            case .groupSelection: return .groupSelection
            case .ungroupSelection: return .ungroupSelection
            case .togglePinImage: return .togglePinImage
            case .recognizeImageText: return .recognizeImageText
            case .annotationRectangle, .annotationEllipse, .annotationText, .annotationBrush,
                 .annotationArrow, .annotationMosaic, .annotationPen, .annotationDiscard: return nil
            }
        }
        // Keep the secondary navigation keys from earlier versions only
        // while the user has not replaced the corresponding binding.
        if held.isEmpty {
            if keyCode == UInt16(kVK_UpArrow),
               (shortcuts[.previous] ?? AppShortcutAction.previous.defaultShortcut)
                   == AppShortcutAction.previous.defaultShortcut {
                return .previous
            }
            if keyCode == UInt16(kVK_DownArrow),
               (shortcuts[.next] ?? AppShortcutAction.next.defaultShortcut)
                   == AppShortcutAction.next.defaultShortcut {
                return .next
            }
            if keyCode == UInt16(kVK_ANSI_KeypadEnter),
               (shortcuts[.paste] ?? AppShortcutAction.paste.defaultShortcut)
                   == AppShortcutAction.paste.defaultShortcut {
                return .paste
            }
        }
        return nil
    }
}

/// Command equivalents may be routed straight to a window instead of through
/// normal keyDown delivery. Use the same scoped handler for both routes.
class ShelfKeyboardPanel: NSPanel {
    weak var shelfKeyMonitor: ShelfKeyMonitor.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if shelfKeyMonitor?.handle(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
protocol ShelfEditHotKey: AnyObject {
    func register(_ shortcut: AppShortcut, allowsUnmodified: Bool, allowsPrintableKey: Bool) -> Bool
    func unregister()
}

extension GlobalHotKey: ShelfEditHotKey {}

/// Receives navigation keys before the search field's editor consumes them.
/// Only events for this panel are intercepted; marked IME text is left alone.
struct ShelfKeyMonitor: NSViewRepresentable {
    var editShortcut: AppShortcut? = nil
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = KeyView(frame: .zero)
        context.coordinator.view = view
        view.coordinator = context.coordinator
        context.coordinator.onKeyDown = onKeyDown
        context.coordinator.setEditShortcut(editShortcut)
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
        context.coordinator.setEditShortcut(editShortcut)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class KeyView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window as? ShelfKeyboardPanel)
        }
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var onKeyDown: ((NSEvent) -> Bool)?
        private var monitor: Any?
        private weak var keyEquivalentPanel: ShelfKeyboardPanel?
        private var windowObservers: [NSObjectProtocol] = []
        private var editShortcut: AppShortcut?
        private var attemptedEditShortcut: AppShortcut?
        private var editHotKey: (any ShelfEditHotKey)?
        private static var nextEditIdentifier: UInt32 = 0x4544_0000

        init(editHotKey: (any ShelfEditHotKey)? = nil) { self.editHotKey = editHotKey }

        func attach(to panel: ShelfKeyboardPanel?) {
            if keyEquivalentPanel === panel { return }
            if keyEquivalentPanel?.shelfKeyMonitor === self {
                keyEquivalentPanel?.shelfKeyMonitor = nil
            }
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            windowObservers.removeAll()
            keyEquivalentPanel = panel
            if let previous = panel?.shelfKeyMonitor, previous !== self {
                previous.releaseEditShortcut()
            }
            panel?.shelfKeyMonitor = self
            if let panel {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                             NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification] {
                    windowObservers.append(NotificationCenter.default.addObserver(
                        forName: name, object: panel, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refreshEditShortcut() }
                    })
                }
            }
            refreshEditShortcut()
        }

        func setEditShortcut(_ shortcut: AppShortcut?) {
            editShortcut = shortcut
            refreshEditShortcut()
            // SwiftUI may update its focused responder after this view.
            DispatchQueue.main.async { [weak self] in self?.refreshEditShortcut() }
        }

        private var editShortcutIsAvailable: Bool {
            guard editShortcut != nil, let window = view?.window,
                  window.isVisible, window.isKeyWindow, window.attachedSheet == nil,
                  keyEquivalentPanel?.shelfKeyMonitor === self else { return false }
            if let editor = window.firstResponder as? NSTextView,
               editor.isEditable || editor.hasMarkedText() { return false }
            return true
        }

        func refreshEditShortcut() {
            guard editShortcutIsAvailable, let shortcut = editShortcut else {
                releaseEditShortcut()
                return
            }
            if attemptedEditShortcut?.hasSameKeys(as: shortcut) == true { return }
            if editHotKey == nil {
                let identifier = Self.nextEditIdentifier
                Self.nextEditIdentifier += 1
                editHotKey = GlobalHotKey(identifier: identifier) { [weak self] in
                    self?.performScopedEditShortcut()
                }
            }
            attemptedEditShortcut = shortcut
            let registered = editHotKey?.register(shortcut, allowsUnmodified: true, allowsPrintableKey: false) == true
#if DEBUG
            ImageGestureTrace.record("shelf edit hotkey registered=\(registered) key=\(shortcut.keyCode) modifiers=\(shortcut.modifierBits)")
#endif
        }

        private func releaseEditShortcut() {
            editHotKey?.unregister()
            attemptedEditShortcut = nil
        }

        func performScopedEditShortcut() {
            guard editShortcutIsAvailable, let shortcut = editShortcut,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: shortcut.modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: shortcut.keyCode) else { return }
#if DEBUG
            ImageGestureTrace.record("shelf edit hotkey dispatch")
#endif
            _ = handle(event)
        }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func handle(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown, let window = view?.window,
                  window.isVisible, window.attachedSheet == nil else { return false }
            if let panel = window as? ShelfKeyboardPanel,
               panel.shelfKeyMonitor !== self { return false }
            // Nonactivating panels can receive a Command equivalent without
            // an associated window. Only the focused panel may claim it.
            if let target = event.window {
                guard target === window else { return false }
            } else if !window.isKeyWindow { return false }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() {
                return false
            }
            return onKeyDown?(event) == true
        }

        func remove() {
            editShortcut = nil
            releaseEditShortcut()
            attach(to: nil)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
