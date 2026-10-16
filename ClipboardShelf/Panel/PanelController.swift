import AppKit
import SwiftUI

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ShelfHostingView: NSHostingView<ShelfView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController {
    private let panel: ShelfPanel
    private let model: AppController
    private(set) var previousApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var targetFrame: NSRect = .zero
    private var displayFrame: NSRect = .zero
    private var outsideClickMonitor: Any?
    private var settingsClickMonitor: Any?
    private var activationObserver: Any?

    var isVisible: Bool { panel.isVisible }

    init(model: AppController) {
        self.model = model
        panel = ShelfPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
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
            Task { @MainActor in self?.lastExternalApplication = application }
        }
    }

    func show() {
        let shouldKeepSettingsBehind = !NSApp.isActive
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            previousApplication = lastExternalApplication
        } else {
            previousApplication = frontmost
            lastExternalApplication = frontmost
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
        targetFrame = PanelLayout.frame(
            in: bounds,
            heightPreference: UserDefaults.standard.string(forKey: "panelHeight")
        )
        let height = targetFrame.height
        let startFrame = targetFrame.offsetBy(dx: 0, dy: -height - 20)
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if shouldKeepSettingsBehind {
            SettingsWindowController.shared.orderBehindOtherApps()
        }
        // Activating a regular app with Settings open can restore Settings as
        // the key window on the next run loop. Restore only the shelf to the
        // foreground after AppKit finishes activation.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, NSApp.isActive else { return }
            panel.makeKeyAndOrderFront(nil)
            if shouldKeepSettingsBehind {
                SettingsWindowController.shared.orderBehindOtherApps()
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
        settingsClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible,
                      SettingsWindowController.shared.contains(event.window) else { return }
                self.hide()
            }
            return event
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func updateHeightIfVisible(_ preference: String) {
        guard panel.isVisible else { return }
        let bounds = panel.screen?.frame ?? displayFrame
        guard !bounds.isEmpty else { return }
        displayFrame = bounds
        let nextFrame = PanelLayout.frame(in: bounds, heightPreference: preference)
        guard nextFrame != targetFrame else { return }
        targetFrame = nextFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(nextFrame, display: true)
        }
    }

    func hide(completion: (() -> Void)? = nil) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let settingsClickMonitor {
            NSEvent.removeMonitor(settingsClickMonitor)
            self.settingsClickMonitor = nil
        }
        guard panel.isVisible else {
            completion?()
            return
        }
        let endFrame = targetFrame.offsetBy(dx: 0, dy: -targetFrame.height - 20)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
            completion?()
        }
    }
}
