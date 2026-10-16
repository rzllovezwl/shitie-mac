import CoreGraphics

enum PanelPlacement: String, CaseIterable, Identifiable {
    case bottom, right, left, top

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

enum PanelLayout {
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
