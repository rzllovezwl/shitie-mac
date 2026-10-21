import AppKit

@main
struct ZoomableImageSmoke {
    static func main() throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 1_200, height: 900))
        let view = ZoomingImageScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        view.show(image, for: UUID())
        view.layoutSubtreeIfNeeded()

        guard view.allowsMagnification else {
            throw Failure.gestureDeliveryDisabled
        }
        let fit = view.zoomScale
        let fittedSize = view.renderedImageSize
        view.apply(ImageZoomAction(kind: .inwards))
        guard view.zoomScale > fit,
              view.renderedImageSize.width > fittedSize.width else {
            throw Failure.zoomInFailed
        }
        view.apply(ImageZoomAction(kind: .outwards))
        guard abs(view.renderedImageSize.width - fittedSize.width) < 1 else {
            throw Failure.zoomOutFailed
        }
        view.apply(ImageZoomAction(kind: .fit))
        guard abs(view.zoomScale - fit) < 0.01 else { throw Failure.fitFailed }

        let preparedView = ZoomingImageScrollView()
        let preparedID = UUID()
        preparedView.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        preparedView.show(image, for: preparedID,
                          initialViewportSize: NSSize(width: 480, height: 360))
        guard abs(preparedView.zoomScale - 0.4) < 0.01,
              preparedView.renderedImageSize == NSSize(width: 480, height: 360) else {
            throw Failure.initialImageNeedsSecondFit
        }
        preparedView.layoutSubtreeIfNeeded()
        guard abs(preparedView.zoomScale - 0.4) < 0.01 else {
            throw Failure.initialImageNeedsSecondFit
        }

        // A small image opens at 100% in a compact preview. Manual zoom still
        // works, and changing the viewport must preserve a user pinch.
        let smallImage = NSImage(size: NSSize(width: 120, height: 240))
        view.show(smallImage, for: UUID())
        view.layoutSubtreeIfNeeded()
        guard abs(view.zoomScale - 1) < 0.01,
              view.renderedImageSize == smallImage.size else {
            throw Failure.smallImageWasEnlarged
        }
        let initialSize = view.renderedImageSize
        let pinchedScale = view.zoomScale * 1.4
        view.applyMagnification(delta: 0.4, centeredAt: NSPoint(x: 60, y: 120))
        guard view.renderedImageSize.width > initialSize.width else {
            throw Failure.pinchDidNotResizeImage
        }
        view.frame.size = NSSize(width: 500, height: 380)
        view.layoutSubtreeIfNeeded()
        guard abs(view.zoomScale - pinchedScale) < 0.01 else {
            throw Failure.pinchLostOnResize
        }

        let reopenedView = ZoomingImageScrollView()
        reopenedView.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        reopenedView.show(smallImage, for: UUID())
        reopenedView.layoutSubtreeIfNeeded()
        let reopenedFit = reopenedView.zoomScale
        let reopenedSize = reopenedView.renderedImageSize
        reopenedView.applyMagnification(delta: 0.25, centeredAt: NSPoint(x: 60, y: 120))
        guard reopenedView.zoomScale > reopenedFit,
              reopenedView.renderedImageSize.width > reopenedSize.width else {
            throw Failure.pinchFailedAfterReopen
        }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw Failure.pixelDimensionsUnavailable }
        let rasterImage = NSImage(size: NSSize(width: 600, height: 400))
        rasterImage.addRepresentation(bitmap)
        guard ImagePixelDimensions.pointSize(of: rasterImage, backingScale: 2)
                == CGSize(width: 300, height: 200),
              ImagePixelDimensions.pointSize(of: rasterImage, backingScale: 1)
                == CGSize(width: 600, height: 400) else {
            throw Failure.screenScaleMismatch
        }
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookImageDimensions-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.pixelDimensionsUnavailable
        }
        try png.write(to: imageURL)
        guard ImagePixelDimensions.pixelSize(at: imageURL)
                == CGSize(width: 600, height: 400) else {
            throw Failure.pixelDimensionsUnavailable
        }
        print("ZoomableImageSmoke passed")
    }

    private enum Failure: Error {
        case gestureDeliveryDisabled, zoomInFailed, zoomOutFailed,
             fitFailed, initialImageNeedsSecondFit, smallImageWasEnlarged, pinchLostOnResize,
             pinchDidNotResizeImage, pinchFailedAfterReopen,
             pixelDimensionsUnavailable, screenScaleMismatch
    }
}
