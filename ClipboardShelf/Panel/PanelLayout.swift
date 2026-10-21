import CoreGraphics

enum PanelPlacement: String, CaseIterable, Identifiable {
    case bottom, left, right, top

    var id: String { rawValue }
    var isVertical: Bool { self == .left || self == .right }

    var title: String {
        switch self {
        case .bottom: "底部"
        case .right: "右侧"
        case .left: "左侧"
        case .top: "顶部"
        }
    }
}

struct PreviewTail: Equatable {
    let edge: PanelPlacement
    /// SwiftUI coordinates: from the left for horizontal edges, from the top for vertical edges.
    let offset: CGFloat
}

enum PanelLayout {
    /// Choose the text window before rendering so its opening animation has
    /// one target size. Inspect only a small prefix of very large records.
    static func textPreviewPreferredSize(for text: String?) -> CGSize {
        var lines = 1
        var columns = 0
        var inspected = 0
        for character in (text ?? "").prefix(1_201) {
            inspected += 1
            if inspected > 1_200 { return CGSize(width: 680, height: 480) }
            if character == "\n" || character == "\r" || character == "\r\n" {
                lines += 1
                columns = 0
                continue
            }
            let width = character == "\t" ? 4
                : character.unicodeScalars.allSatisfy({ $0.value < 128 }) ? 1 : 2
            if columns + width > 64 {
                lines += 1
                columns = 0
            }
            columns += width
            if lines > 12 { return CGSize(width: 680, height: 480) }
        }
        if lines <= 4 { return CGSize(width: 560, height: 360) }
        if lines <= 12 { return CGSize(width: 620, height: 420) }
        return CGSize(width: 680, height: 480)
    }

    /// The image canvas follows the source pixels. Controls and metadata need
    /// their own space, so a tiny image still has a usable preview window.
    static func imagePreviewPreferredSize(
        pixelSize: CGSize?,
        backingScale: CGFloat,
        availableSize: CGSize,
        placement: PanelPlacement,
        isFileReference: Bool
    ) -> CGSize {
        let maximum = CGSize(
            width: max(1, min(1240, availableSize.width)),
            height: max(1, min(780, availableSize.height))
        )
        let minimum = CGSize(
            width: min(isFileReference ? 460 : 360, maximum.width),
            // Leave room for the image controls when More Info is expanded.
            height: min(isFileReference ? 365 : 345, maximum.height)
        )
        guard let pixelSize, pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: min(560, maximum.width),
                          height: min(440, maximum.height))
        }

        // ClipboardDetailView reserves 145 pt below its canvas, adds 14 pt
        // padding on each side, and the bubble has a 10 pt pointing tip.
        let horizontalChrome: CGFloat = 28 + (placement.isVertical ? 10 : 0)
        let verticalChrome: CGFloat = 173 + (placement.isVertical ? 0 : 10)
        let scale = backingScale.isFinite ? max(1, backingScale) : 1
        let imageSize = CGSize(width: pixelSize.width / scale,
                               height: pixelSize.height / scale)
        let viewport = CGSize(width: max(1, maximum.width - horizontalChrome),
                              height: max(1, maximum.height - verticalChrome))
        let fit = min(1, viewport.width / imageSize.width,
                      viewport.height / imageSize.height)
        return CGSize(
            width: min(maximum.width, max(minimum.width,
                ceil(imageSize.width * fit + horizontalChrome))),
            height: min(maximum.height, max(minimum.height,
                ceil(imageSize.height * fit + verticalChrome)))
        )
    }

    static func cardScreenFrame(
        shelfFrame: CGRect,
        cardFrame: CGRect?
    ) -> CGRect? {
        guard let cardFrame, cardFrame.width > 0, cardFrame.height > 0,
              CGRect(origin: .zero, size: shelfFrame.size).intersects(cardFrame) else { return nil }
        return CGRect(
            x: shelfFrame.minX + cardFrame.minX,
            y: shelfFrame.maxY - cardFrame.maxY,
            width: cardFrame.width,
            height: cardFrame.height
        )
    }

    static func detailPreviewFrame(
        in bounds: CGRect,
        avoiding shelfFrame: CGRect,
        placement: PanelPlacement,
        preferredSize: CGSize,
        cardFrame: CGRect? = nil
    ) -> CGRect {
        let region = detailPreviewRegion(in: bounds, avoiding: shelfFrame,
                                         placement: placement, cardFrame: cardFrame)
        let width = max(1, min(region.width, preferredSize.width))
        let height = max(1, min(region.height, preferredSize.height))
        let preferredX = cardFrame.map { $0.minX - 12 } ?? region.midX - width / 2
        let preferredY = cardFrame.map { $0.maxY - height + 12 } ?? region.midY - height / 2
        return CGRect(
            x: placement.isVertical
                ? (placement == .left ? region.minX : region.maxX - width)
                : min(region.maxX - width, max(region.minX, preferredX)),
            y: placement.isVertical
                ? min(region.maxY - height, max(region.minY, preferredY))
                : (placement == .bottom ? region.minY : region.maxY - height),
            width: width,
            height: height
        )
    }

    static func detailPreviewAvailableSize(
        in bounds: CGRect,
        avoiding shelfFrame: CGRect,
        placement: PanelPlacement,
        cardFrame: CGRect? = nil
    ) -> CGSize {
        detailPreviewRegion(in: bounds, avoiding: shelfFrame,
                            placement: placement, cardFrame: cardFrame).size
    }

    private static func detailPreviewRegion(
        in bounds: CGRect,
        avoiding shelfFrame: CGRect,
        placement: PanelPlacement,
        cardFrame: CGRect?
    ) -> CGRect {
        let inset: CGFloat = 20
        // The transparent tip occupies the outer 10 pt of the preview window.
        // Its end sits 1 pt away from the selected card.
        let gap: CGFloat = 1
        let available = bounds.insetBy(dx: inset, dy: inset)
        var region = available
        switch placement {
        case .bottom:
            region.origin.y = max(available.minY, (cardFrame?.maxY ?? shelfFrame.maxY) + gap)
            region.size.height = max(0, available.maxY - region.minY)
        case .top:
            region.size.height = max(0, min(available.height,
                (cardFrame?.minY ?? shelfFrame.minY) - gap - available.minY))
        case .left:
            region.origin.x = max(available.minX, (cardFrame?.maxX ?? shelfFrame.maxX) + gap)
            region.size.width = max(0, available.maxX - region.minX)
        case .right:
            region.size.width = max(0, min(available.width,
                (cardFrame?.minX ?? shelfFrame.minX) - gap - available.minX))
        }
        // On a very small display, keep the preview usable even if it must
        // overlap part of the shelf. The shelf stays at its original frame.
        if region.width < 440 || region.height < 380 { region = available }
        return region
    }

    static func previewTail(
        previewFrame: CGRect, cardFrame: CGRect, placement: PanelPlacement
    ) -> PreviewTail {
        let rawOffset = placement.isVertical
            ? previewFrame.maxY - cardFrame.midY
            : cardFrame.midX - previewFrame.minX
        let dimension = placement.isVertical ? previewFrame.height : previewFrame.width
        return PreviewTail(edge: placement,
                           offset: min(dimension - 34, max(34, rawOffset)))
    }

    static func frame(
        in bounds: CGRect,
        placement: PanelPlacement = .bottom,
        heightPreference: String?
    ) -> CGRect {
        let inset: CGFloat = 10
        let availableWidth = max(CGFloat(1), bounds.width - inset * 2)
        let availableHeight = max(CGFloat(1), bounds.height - inset * 2)
        let preferredSide = dimension(for: heightPreference, screenLength: bounds.width)
        let preferredHorizontal = dimension(for: heightPreference, screenLength: bounds.height)
        let width = placement.isVertical ? min(preferredSide, availableWidth) : availableWidth
        let height = placement.isVertical ? availableHeight : min(preferredHorizontal, availableHeight)
        let x = placement == .right ? bounds.maxX - inset - width : bounds.minX + inset
        let y = placement == .top ? bounds.maxY - inset - height : bounds.minY + inset
        return CGRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    static func offscreenFrame(from frame: CGRect, placement: PanelPlacement) -> CGRect {
        switch placement {
        case .bottom: frame.offsetBy(dx: 0, dy: -frame.height - 20)
        case .top: frame.offsetBy(dx: 0, dy: frame.height + 20)
        case .left: frame.offsetBy(dx: -frame.width - 20, dy: 0)
        case .right: frame.offsetBy(dx: frame.width + 20, dy: 0)
        }
    }

    static func cardSize(in availableSize: CGSize, placement: PanelPlacement) -> CGSize {
        if placement.isVertical {
            let width = max(1, availableSize.width - 8)
            return CGSize(width: width, height: min(400, max(220, width * 0.78)))
        }
        let height = max(1, availableSize.height - 8)
        return CGSize(width: min(340, max(128, height * 190 / 252)), height: height)
    }

    private static func dimension(for preference: String?, screenLength: CGFloat) -> CGFloat {
        let preferred: CGFloat
        switch preference {
        case "compact":
            preferred = 300
        case "large":
            preferred = min(520, max(380, screenLength * 0.52))
        default:
            preferred = min(380, max(300, screenLength * 0.38))
        }
        return preferred
    }
}
