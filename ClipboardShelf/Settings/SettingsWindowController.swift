import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {}

    func showDockIcon() {
        _ = NSApp.setActivationPolicy(.regular)
    }

    func open() {
        showDockIcon()

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ClipHoook 设置"
            window.minSize = NSSize(width: 520, height: 480)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: AppController.shared))
            window.delegate = self
            window.center()
            self.window = window
        }

        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible == false else { return }
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}
