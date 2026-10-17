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

    static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        searchFocused: Bool,
        searchIsEmpty: Bool
    ) -> ShelfKeyboardAction? {
        let held = modifiers.intersection([.command, .control, .option, .shift])
        if keyCode == UInt16(kVK_ANSI_F), held == [.command] { return .focusSearch }
        if keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            switch held {
            case []: return .paste
            case [.option]: return .pastePlainText
            case [.command]: return .copyOnly
            default: return nil
            }
        }
        guard held.isEmpty else { return nil }
        switch Int(keyCode) {
        case kVK_UpArrow: return .previous
        case kVK_DownArrow: return .next
        case kVK_LeftArrow where !searchFocused || searchIsEmpty: return .previous
        case kVK_RightArrow where !searchFocused || searchIsEmpty: return .next
        case kVK_Space where !searchFocused: return .toggleDetail
        case kVK_Escape: return .dismiss
        default: return nil
        }
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
