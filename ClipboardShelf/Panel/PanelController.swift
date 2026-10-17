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
    private var currentPlacement: PanelPlacement = .bottom
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
        currentPlacement = PanelPlacement(
            rawValue: UserDefaults.standard.string(forKey: "panelPlacement") ?? "bottom"
        ) ?? .bottom
        targetFrame = PanelLayout.frame(
            in: bounds,
            placement: currentPlacement,
            heightPreference: UserDefaults.standard.string(forKey: "panelHeight")
        )
        let startFrame = PanelLayout.offscreenFrame(from: targetFrame, placement: currentPlacement)
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeMain()
        SettingsWindowController.shared.keepBehindOtherAppsWhilePanelIsOpen()
        _ = NSRunningApplication.current.activate(options: [])
        // Activation can finish on the next run loop. Keep keyboard navigation
        // and trackpad gestures directed to the shelf after that transition.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible, NSApp.isActive else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeMain()
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                // During activation, the first click on our panel can reach
                // the global monitor. Treat the visible and destination frames
                // as inside so header actions cannot dismiss the panel.
                guard !self.panel.frame.contains(clickLocation),
                      !self.targetFrame.contains(clickLocation) else { return }
                self.hide()
            }
        }
        settingsClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible,
                      SettingsWindowController.shared.contains(event.window) else { return }
                SettingsWindowController.shared.restoreForInteraction()
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
        guard nextFrame != targetFrame else { return }
        currentPlacement = placement
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
        let endFrame = PanelLayout.offscreenFrame(from: targetFrame, placement: currentPlacement)
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
