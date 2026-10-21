import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private static let behindRegularWindows = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    private var window: NSWindow?
    private var isBehindRegularWindows = false
    private var switchedToAccessoryForPanel = false

    private override init() {}

    var hasVisibleWindow: Bool {
        window?.isVisible == true && window?.isMiniaturized == false
    }

    func showDockIcon() {
        _ = NSApp.setActivationPolicy(.regular)
    }

    func contains(_ eventWindow: NSWindow?) -> Bool {
        guard let window, let eventWindow else { return false }
        return eventWindow === window || eventWindow.sheetParent === window
    }

    func prepareForPanelPresentation() {
        guard let window, window.isVisible || window.isMiniaturized else {
            _ = NSApp.setActivationPolicy(.accessory)
            return
        }
        // Keep Settings ordered in its own Space. The panel needs accessory
        // policy to appear over another app's full-screen Space, but ordering
        // Settings out here would make an open window appear to have closed.
        if window.isMiniaturized || !window.isOnActiveSpace {
            if NSApp.activationPolicy() == .regular {
                switchedToAccessoryForPanel = true
            }
            _ = NSApp.setActivationPolicy(.accessory)
            return
        }
        // If Settings was the active window, leave it visible behind the
        // shelf. Only lower it when another app was already frontmost, so an
        // image-preview activation cannot unexpectedly raise Settings.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier !=
                NSRunningApplication.current.processIdentifier else {
            return
        }
        window.level = Self.behindRegularWindows
        isBehindRegularWindows = true
    }

    func restoreAfterPanelPresentation() {
        guard let window else { return }
        if switchedToAccessoryForPanel {
            switchedToAccessoryForPanel = false
            showDockIcon()
            // Some macOS versions hide regular windows during a policy switch.
            // Restore visibility only if that happened; never close Settings.
            if !window.isVisible && !window.isMiniaturized {
                window.orderBack(nil)
            }
        }
        if isBehindRegularWindows {
            window.level = .normal
            isBehindRegularWindows = false
            if NSWorkspace.shared.frontmostApplication?.processIdentifier !=
                NSRunningApplication.current.processIdentifier {
                window.orderBack(nil)
            }
        }
    }

    func restoreForInteraction() {
        showDockIcon()
        guard isBehindRegularWindows else { return }
        window?.level = .normal
        isBehindRegularWindows = false
    }

    func restoreAfterAppDeactivates() {
        guard isBehindRegularWindows else { return }
        window?.level = .normal
        isBehindRegularWindows = false
        // The user has switched to another app. Restoring the normal level
        // must not raise Settings over that app.
        window?.orderBack(nil)
    }

    func open() {
        switchedToAccessoryForPanel = false
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // The first accessory -> regular policy change can finish on the next
        // run loop. Reassert only this window's order then, after the shelf is
        // already gone, so the Dock icon never appears without Settings.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.isVisible, !self.isBehindRegularWindows else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              contains(event.window) else { return }
        restoreForInteraction()
    }

    func windowWillClose(_ notification: Notification) {
        switchedToAccessoryForPanel = false
        restoreForInteraction()
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible == false else { return }
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}
