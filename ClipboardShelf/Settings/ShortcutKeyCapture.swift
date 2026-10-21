import AppKit
import Carbon
import SwiftUI

/// Takes keyboard focus only while a shortcut is being edited in Settings.
struct ShortcutKeyCapture: NSViewRepresentable {
    let active: Bool
    let onKeyDown: (NSEvent) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        CaptureView()
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.active = active
        view.onKeyDown = onKeyDown
        view.onCancel = onCancel
        if active {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.active, let window = view.window,
                      window.isKeyWindow, window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        } else if view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: ()) {
        view.stop()
    }

    final class CaptureView: NSView {
        var active = false
        var onKeyDown: ((NSEvent) -> Void)?
        var onCancel: (() -> Void)?
        private var resignObserver: NSObjectProtocol?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
            guard let window else { return }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self, self.active else { return }
                self.onCancel?()
            }
        }

        override func keyDown(with event: NSEvent) {
            guard active else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel?()
            } else {
                onKeyDown?(event)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard active else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        func stop() {
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
            onKeyDown = nil
            onCancel = nil
            active = false
        }

        deinit {
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }
}
