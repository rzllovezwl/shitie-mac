import AppKit
import ImageIO
import SwiftUI

#if DEBUG
enum ImageGestureTrace {
    static let fileURL = URL(fileURLWithPath: "/tmp/ClipHoookImageGesture-\(ProcessInfo.processInfo.processIdentifier).log")

    static func record(_ message: String) {
        let data = Data("\(Date().timeIntervalSince1970) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
}
#endif

struct ImageZoomAction {
    enum Kind { case inwards, outwards, actualSize, fit }
    let id = UUID()
    let kind: Kind
}

struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let entryID: UUID
    let backingScale: CGFloat
    let initialViewportSize: CGSize
    let zoomAction: ImageZoomAction?
    let onZoomChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ZoomingImageScrollView {
        ZoomingImageScrollView()
    }

    func updateNSView(_ view: ZoomingImageScrollView, context: Context) {
        view.onZoomChange = onZoomChange
        view.show(image, for: entryID, backingScale: backingScale,
                  initialViewportSize: initialViewportSize)
        if let zoomAction { view.apply(zoomAction) }
    }
}

enum ImagePixelDimensions {
    /// Read only the image header. The preview window can be sized before the
    /// full image is decoded and the SwiftUI detail view is installed.
    static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
              let width = (properties as NSDictionary)[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = (properties as NSDictionary)[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    static func pixelSize(of image: NSImage) -> CGSize? {
        image.representations
            .filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { Double($0.pixelsWide) * Double($0.pixelsHigh)
                < Double($1.pixelsWide) * Double($1.pixelsHigh) }
            .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
    }

    static func pointSize(of image: NSImage, backingScale: CGFloat) -> CGSize {
        guard let pixels = pixelSize(of: image) else { return image.size }
        let scale = backingScale.isFinite ? max(1, backingScale) : 1
        return CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }
}

private final class CenteringClipView: NSClipView {
    private static let lightCheckerboard = checkerboardColor(base: 0.96, alternate: 0.86)
    private static let darkCheckerboard = checkerboardColor(base: 0.18, alternate: 0.25)

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // The checkerboard represents transparent pixels in the image, not
        // unused space in the preview window (notably beside portrait images).
        guard let documentView else { return }
        let imageRect = dirtyRect.intersection(documentView.frame)
        guard !imageRect.isNull, !imageRect.isEmpty else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? Self.darkCheckerboard : Self.lightCheckerboard).setFill()
        NSBezierPath(rect: imageRect).fill()
    }

    private static func checkerboardColor(base: CGFloat, alternate: CGFloat) -> NSColor {
        let tile: CGFloat = 12
        let image = NSImage(size: NSSize(width: tile * 2, height: tile * 2), flipped: false) { rect in
            NSColor(calibratedWhite: base, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor(calibratedWhite: alternate, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: tile, height: tile)).fill()
            NSBezierPath(rect: NSRect(x: tile, y: tile, width: tile, height: tile)).fill()
            return true
        }
        return NSColor(patternImage: image)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

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
    private var originalImageSize: NSSize = .zero
    private var lastViewportSize: NSSize = .zero
    private var needsInitialFit = false
    private var userHasZoomed = false
    private var lastZoomActionID: UUID?
    private var magnifyEventMonitor: Any?
    private var backgroundMagnifyEventMonitor: Any?
    private var minimumZoomScale: CGFloat = 0.25
    private var maximumZoomScale: CGFloat = 8
    private(set) var zoomScale: CGFloat = 1
    var onZoomChange: ((CGFloat) -> Void)?
    private var gestureCount = 0
    private var backgroundGestureCount = 0
    private var lastReportedZoomPercentage: Int?

    var renderedImageSize: NSSize { imageView.frame.size }

    init() {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        contentView = CenteringClipView()
        contentView.drawsBackground = false
        // AppKit only delivers trackpad magnify events to this scroll view
        // while magnification is enabled. The local event monitor consumes
        // those events and scales the image document itself instead of relying
        // on the scroll view's magnification rendering in this panel.
        allowsMagnification = true
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        imageView.imageScaling = .scaleProportionallyUpOrDown
        documentView = imageView
        // SwiftUI may keep this NSScrollView alive while the shelf panel is
        // ordered out. Intercept magnify events before view/gesture dispatch so
        // the next presentation does not depend on a recognizer's old state.
        magnifyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, let window = self.window,
                  window.isVisible, event.window === window,
                  !self.isHiddenOrHasHiddenAncestor else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            let imagePoint = self.imageView.convert(point, from: self)
            let delta = event.magnification
            self.gestureCount += 1
#if DEBUG
            let sample = self.gestureCount == 1 || self.gestureCount.isMultiple(of: 12)
            if sample {
                let root = window.contentView
                let rootPoint = root?.superview?.convert(event.locationInWindow, from: nil)
                    ?? event.locationInWindow
                let hit = root?.hitTest(rootPoint)
                ImageGestureTrace.record("event view=\(ObjectIdentifier(self).hashValue) count=\(self.gestureCount) appActive=\(NSApp.isActive) panelKey=\(window.isKeyWindow) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") insideVisibleView=\(hit === self || hit?.isDescendant(of: self) == true) oldScale=\(self.zoomScale) oldFrame=\(self.imageView.frame) delta=\(delta)")
            }
#endif
            // A local monitor runs before AppKit finishes dispatching this
            // event. Resize on the next turn so SwiftUI/AppKit layout cannot
            // overwrite the image frame later in the same event pass.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, window.isVisible else { return }
                self.applyMagnification(delta: delta, centeredAt: imagePoint)
#if DEBUG
                if sample {
                    ImageGestureTrace.record("applied view=\(ObjectIdentifier(self).hashValue) count=\(self.gestureCount) newScale=\(self.zoomScale) newFrame=\(self.imageView.frame)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        guard let self else { return }
                        ImageGestureTrace.record("settled view=\(ObjectIdentifier(self).hashValue) scale=\(self.zoomScale) frame=\(self.imageView.frame) window=\(self.window?.windowNumber ?? -1)")
                    }
                }
#endif
            }
            return nil
        }
        // A nonactivating panel can be key while its source app remains
        // frontmost. AppKit then sends trackpad gestures to that app, so the
        // local monitor never sees them. Observe only magnification events
        // sent to other apps, and use them only while the visible image view
        // lies under the pointer. The monitor never reads clipboard content.
        backgroundMagnifyEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
            let delta = event.magnification
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window,
                      window.isVisible, window.isOnActiveSpace,
                      !self.isHiddenOrHasHiddenAncestor else { return }
                let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                let point = self.convert(windowPoint, from: nil)
                guard self.bounds.contains(point) else { return }
                let imagePoint = self.imageView.convert(point, from: self)
                self.backgroundGestureCount += 1
#if DEBUG
                if self.backgroundGestureCount == 1 || self.backgroundGestureCount.isMultiple(of: 12) {
                    ImageGestureTrace.record("background event view=\(ObjectIdentifier(self).hashValue) count=\(self.backgroundGestureCount) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") panelKey=\(window.isKeyWindow) activeSpace=\(window.isOnActiveSpace) oldScale=\(self.zoomScale) delta=\(delta)")
                }
#endif
                self.applyMagnification(delta: delta, centeredAt: imagePoint)
            }
        }
#if DEBUG
        ImageGestureTrace.record("image gesture monitors local=\(magnifyEventMonitor != nil) background=\(backgroundMagnifyEventMonitor != nil)")
#endif
    }

    deinit {
        if let magnifyEventMonitor {
            NSEvent.removeMonitor(magnifyEventMonitor)
        }
        if let backgroundMagnifyEventMonitor {
            NSEvent.removeMonitor(backgroundMagnifyEventMonitor)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ image: NSImage, for entryID: UUID, backingScale: CGFloat? = nil,
              initialViewportSize: NSSize? = nil) {
        guard displayedEntryID != entryID else { return }
        displayedEntryID = entryID
        imageView.image = image
        // Keep the window's initial sizing and the 100% zoom baseline in sync.
        let backingScale = backingScale ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 1
        originalImageSize = ImagePixelDimensions.pointSize(
            of: image, backingScale: backingScale
        )
        let viewport = initialViewportSize ?? contentView.bounds.size
        let canFit = viewport.width > 0 && viewport.height > 0 &&
            originalImageSize.width > 0 && originalImageSize.height > 0
        let fit = canFit
            ? min(1, viewport.width / originalImageSize.width,
                  viewport.height / originalImageSize.height) : 1
        zoomScale = fit
        imageView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: originalImageSize.width * fit,
                         height: originalImageSize.height * fit)
        )
        contentView.needsDisplay = true
        lastReportedZoomPercentage = nil
        needsInitialFit = !canFit
        userHasZoomed = false
        lastViewportSize = canFit ? viewport : .zero
        minimumZoomScale = min(0.25, fit)
        maximumZoomScale = max(8, fit * 8)
        needsLayout = true
        if canFit {
            lastReportedZoomPercentage = Int((fit * 100).rounded())
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayedEntryID == entryID,
                      abs(self.zoomScale - fit) < 0.0001 else { return }
                self.onZoomChange?(fit)
            }
        }
    }

    func apply(_ action: ImageZoomAction) {
        guard lastZoomActionID != action.id else { return }
        lastZoomActionID = action.id
        guard displayedEntryID != nil else { return }
        layoutSubtreeIfNeeded()
        let viewport = contentView.bounds
        let center = NSPoint(x: viewport.midX, y: viewport.midY)
        switch action.kind {
        case .inwards:
            userHasZoomed = true
            setZoomScale(zoomScale * 1.5, centeredAt: center)
        case .outwards:
            userHasZoomed = true
            setZoomScale(zoomScale / 1.5, centeredAt: center)
        case .actualSize:
            userHasZoomed = true
            setZoomScale(1, centeredAt: center)
        case .fit:
            userHasZoomed = false
            needsInitialFit = true
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    func applyMagnification(delta: CGFloat, centeredAt point: NSPoint) {
        guard displayedEntryID != nil, delta.isFinite else { return }
        layoutSubtreeIfNeeded()
        userHasZoomed = true
        let factor = min(2, max(0.5, 1 + delta))
        setZoomScale(zoomScale * factor, centeredAt: point)
    }

    private func setZoomScale(_ requestedScale: CGFloat, centeredAt point: NSPoint) {
        guard originalImageSize.width > 0, originalImageSize.height > 0 else { return }
        let next = min(maximumZoomScale, max(minimumZoomScale, requestedScale))
        guard next.isFinite, abs(next - zoomScale) > 0.0001 else { return }

        let oldSize = imageView.frame.size
        let viewport = contentView.bounds
        let anchor = NSPoint(
            x: min(oldSize.width, max(0, point.x)),
            y: min(oldSize.height, max(0, point.y))
        )
        let offset = NSPoint(x: anchor.x - viewport.minX, y: anchor.y - viewport.minY)
        zoomScale = next
        let newSize = NSSize(width: originalImageSize.width * next,
                             height: originalImageSize.height * next)
        imageView.setFrameSize(newSize)
        imageView.needsDisplay = true
        contentView.needsDisplay = true
        contentView.scroll(to: NSPoint(
            x: anchor.x / oldSize.width * newSize.width - offset.x,
            y: anchor.y / oldSize.height * newSize.height - offset.y
        ))
        reflectScrolledClipView(contentView)
        let percentage = Int((next * 100).rounded())
        if percentage != lastReportedZoomPercentage {
            lastReportedZoomPercentage = percentage
            DispatchQueue.main.async { [weak self] in
                self?.onZoomChange?(next)
            }
        }
    }

    override func layout() {
        super.layout()
        guard displayedEntryID != nil,
              originalImageSize.width > 0,
              originalImageSize.height > 0 else { return }

        let viewport = contentView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        guard needsInitialFit ||
                abs(viewport.width - lastViewportSize.width) > 0.5 ||
                abs(viewport.height - lastViewportSize.height) > 0.5 else { return }

        // Small images open at their real size; only oversized images shrink
        // to the available canvas. The user can still zoom in manually.
        let fit = min(1, viewport.width / originalImageSize.width,
                      viewport.height / originalImageSize.height)
        lastViewportSize = viewport
        minimumZoomScale = min(0.25, fit)
        maximumZoomScale = max(8, fit * 8)

        if needsInitialFit || !userHasZoomed {
            needsInitialFit = false
            setZoomScale(fit, centeredAt: NSPoint(x: imageView.frame.midX,
                                                  y: imageView.frame.midY))
        }
    }
}
