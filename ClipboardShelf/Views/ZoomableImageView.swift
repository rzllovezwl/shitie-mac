import AppKit
import SwiftUI

struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let entryID: UUID

    func makeNSView(context: Context) -> ZoomingImageScrollView {
        ZoomingImageScrollView()
    }

    func updateNSView(_ view: ZoomingImageScrollView, context: Context) {
        view.show(image, for: entryID)
    }
}

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }

        // Fit-to-view leaves free space on one axis; center the image there.
        if documentView.frame.width < bounds.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if documentView.frame.height < bounds.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }
        return bounds
    }
}

final class ZoomingImageScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var displayedEntryID: UUID?
    private var lastViewportSize: NSSize = .zero
    private var needsInitialFit = false
    private var userHasZoomed = false

    // Keep the detail view's space and arrow-key navigation active after scrolling.
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        contentView = CenteringClipView()
        allowsMagnification = true
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        imageView.imageScaling = .scaleNone
        documentView = imageView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidStartMagnifying(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(_ image: NSImage, for entryID: UUID) {
        guard displayedEntryID != entryID else { return }
        displayedEntryID = entryID
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        needsInitialFit = true
        userHasZoomed = false
        lastViewportSize = .zero
        needsLayout = true
    }

    @objc private func userDidStartMagnifying(_ notification: Notification) {
        userHasZoomed = true
    }

    override func magnify(with event: NSEvent) {
        userHasZoomed = true
        super.magnify(with: event)
    }

    override func layout() {
        super.layout()
        guard displayedEntryID != nil,
              imageView.frame.width > 0,
              imageView.frame.height > 0 else { return }

        let viewport = contentView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        guard needsInitialFit ||
                abs(viewport.width - lastViewportSize.width) > 0.5 ||
                abs(viewport.height - lastViewportSize.height) > 0.5 else { return }

        let fit = min(1, viewport.width / imageView.frame.width, viewport.height / imageView.frame.height)
        lastViewportSize = viewport
        minMagnification = fit
        maxMagnification = max(4, fit * 8)

        if needsInitialFit || !userHasZoomed {
            needsInitialFit = false
            setMagnification(fit, centeredAt: NSPoint(x: imageView.frame.midX, y: imageView.frame.midY))
            let visibleSize = contentView.bounds.size
            contentView.scroll(to: NSPoint(
                x: (imageView.frame.width - visibleSize.width) / 2,
                y: (imageView.frame.height - visibleSize.height) / 2
            ))
            reflectScrolledClipView(contentView)
        }
    }
}
