import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let behindRegularWindows = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    private var window: NSWindow?
    private var isBehindRegularWindows = false

    private override init() {}

    func showDockIcon() {
        _ = NSApp.setActivationPolicy(.regular)
    }

    func contains(_ eventWindow: NSWindow?) -> Bool {
        guard let window, let eventWindow else { return false }
        return eventWindow === window || eventWindow.sheetParent === window
    }

    func keepBehindOtherAppsWhilePanelIsOpen() {
        guard let window, window.isVisible, !window.isMiniaturized else { return }
        // Activating the app can raise every open window, regardless of which
        // window was made key first. A lower window level keeps Settings behind
        // other apps while the shelf remains fully interactive above them.
        window.level = Self.behindRegularWindows
        isBehindRegularWindows = true
    }

    func restoreForInteraction() {
        guard isBehindRegularWindows else { return }
        window?.level = .normal
        isBehindRegularWindows = false
    }

    func restoreAfterAppDeactivates() {
        guard isBehindRegularWindows else { return }
        restoreForInteraction()
        // The user has switched to another app. Restoring the normal level
        // must not raise Settings over that app.
        window?.orderBack(nil)
    }

    func open() {
        AppController.shared.closePanel()
        showDockIcon()
        restoreForInteraction()

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

    func windowDidBecomeKey(_ notification: Notification) {
        guard isBehindRegularWindows,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              contains(event.window) else { return }
        restoreForInteraction()
    }

    func windowWillClose(_ notification: Notification) {
        restoreForInteraction()
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible == false else { return }
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}
