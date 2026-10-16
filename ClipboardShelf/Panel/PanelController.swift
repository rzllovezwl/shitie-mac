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
    private var outsideClickMonitor: Any?
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
        let preferredHeight: CGFloat
        switch UserDefaults.standard.string(forKey: "panelHeight") {
        case "compact": preferredHeight = 300
        case "large": preferredHeight = min(520, max(380, bounds.height * 0.52))
        default: preferredHeight = min(380, max(300, bounds.height * 0.38))
        }
        let height = min(preferredHeight, bounds.height - 20)
        targetFrame = NSRect(
            x: bounds.minX + 10,
            y: bounds.minY + 10,
            width: bounds.width - 20,
            height: height
        )
        let startFrame = targetFrame.offsetBy(dx: 0, dy: -height - 20)
        panel.setFrame(startFrame, display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func hide(completion: (() -> Void)? = nil) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
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
