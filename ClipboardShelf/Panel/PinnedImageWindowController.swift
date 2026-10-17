import AppKit
import SwiftUI

@MainActor
final class PinnedImageWindowController: NSObject, NSWindowDelegate {
    private var windows: [UUID: NSPanel] = [:]

    func show(entryID: UUID, image: NSImage) {
        if let existing = windows[entryID] {
            existing.orderFrontRegardless()
            return
        }

        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main else { return }
        let frame = PinnedImageLayout.frame(
            imageSize: image.size,
            visibleFrame: screen.visibleFrame,
            cursor: cursor
        )
        let window = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "固定图片"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 240, height: 170)
        window.contentView = NSHostingView(rootView:
            ZoomableImageView(image: image, entryID: entryID)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityLabel("固定图片；拖动标题栏移动，拖动边缘调整大小，双指捏合缩放")
        )
        window.delegate = self
        windows[entryID] = window
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              let entryID = windows.first(where: { $0.value === closingWindow })?.key else { return }
        windows.removeValue(forKey: entryID)
    }
}
