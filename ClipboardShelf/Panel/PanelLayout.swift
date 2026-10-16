import CoreGraphics

enum PanelLayout {
    static func frame(in bounds: CGRect, heightPreference: String?) -> CGRect {
        let inset: CGFloat = 10
        let width = max(CGFloat(1), bounds.width - inset * 2)
        let resolvedHeight = height(for: heightPreference, screenHeight: bounds.height)
        return CGRect(
            x: bounds.minX + inset,
            y: bounds.minY + inset,
            width: width,
            height: resolvedHeight
        )
    }

    private static func height(for preference: String?, screenHeight: CGFloat) -> CGFloat {
        let preferred: CGFloat
        switch preference {
        case "compact":
            preferred = 300
        case "large":
            preferred = min(520, max(380, screenHeight * 0.52))
        default:
            preferred = min(380, max(300, screenHeight * 0.38))
        }
        return min(preferred, max(1, screenHeight - 20))
    }
}
