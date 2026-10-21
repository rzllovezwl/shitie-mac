import AppKit
import Carbon
import SwiftUI

enum ShelfKeyboardAction: Equatable {
    case previous
    case next
    case paste
    case pastePlainText
    case copyOnly
    case toggleDetail
    case dismiss
    case focusSearch
    case deleteSelected

    static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        searchFocused: Bool,
        searchIsEmpty: Bool,
        shortcuts: [AppShortcutAction: AppShortcut] = [:]
    ) -> ShelfKeyboardAction? {
        let held = modifiers.intersection([.command, .control, .option, .shift])
        if keyCode == UInt16(kVK_Escape), held.isEmpty { return .dismiss }
        for action in AppShortcutAction.allCases where action != .openPanel {
            let shortcut = shortcuts[action] ?? action.defaultShortcut
            guard shortcut.matches(keyCode: keyCode, modifiers: held) else { continue }
            if action == .copyOnly, searchFocused { return nil }
            if (action == .previous || action == .next),
               searchFocused, !searchIsEmpty, held.isEmpty,
               (keyCode == UInt16(kVK_LeftArrow) || keyCode == UInt16(kVK_RightArrow)) {
                return nil
            }
            switch action {
            case .openPanel: break
            case .deleteEntry: return .deleteSelected
            case .focusSearch: return .focusSearch
            case .previous: return .previous
            case .next: return .next
            case .toggleDetail: return searchFocused && held.isEmpty ? nil : .toggleDetail
            case .paste: return .paste
            case .pastePlainText: return .pastePlainText
            case .copyOnly: return .copyOnly
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

/// Receives navigation keys before the search field's editor consumes them.
/// Only events for this panel are intercepted; marked IME text is left alone.
struct ShelfKeyMonitor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.onKeyDown = onKeyDown
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        weak var view: NSView?
        var onKeyDown: ((NSEvent) -> Bool)?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window,
                      window.isKeyWindow, event.window === window else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() {
                    return event
                }
                return self.onKeyDown?(event) == true ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }
}
