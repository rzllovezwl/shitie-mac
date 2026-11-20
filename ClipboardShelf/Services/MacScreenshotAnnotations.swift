import AppKit
import CoreImage
import CoreText
import ImageIO
import NaturalLanguage
import SwiftUI
import Translation
import UniformTypeIdentifiers

enum ScreenshotAnnotationPreferences {
    static let remembersToolAndStyleKey = "ScreenshotAnnotation.remembersToolAndStyle"
    static let lastToolKey = "ScreenshotAnnotation.lastTool"
    static let startupToolKey = "ScreenshotAnnotation.startupTool"
    static let rememberLastTool = -1
    static let arrowStyleKey = "ScreenshotAnnotation.arrowStyle"
    static let rectangleStyleKey = "ScreenshotAnnotation.rectangleStyle"
    static let ellipseStyleKey = "ScreenshotAnnotation.ellipseStyle"
    static let magnifierStyleKey = "ScreenshotAnnotation.magnifierStyle"
    static let highlighterOpacityKey = "ScreenshotAnnotation.highlighterOpacity"
    static let textStyleKey = "ScreenshotAnnotation.textStyle"
    static let arrowScaleKey = "ScreenshotAnnotation.arrowScale"
    static let rectangleWidthKey = "ScreenshotAnnotation.rectangleWidthPoints"
    static let discardWidthKey = "ScreenshotAnnotation.discardWidthPoints"
    static let ellipseWidthKey = "ScreenshotAnnotation.ellipseWidthPoints"
    static let brushWidthKey = "ScreenshotAnnotation.brushWidthPoints"
    static let penWidthKey = "ScreenshotAnnotation.penWidthPoints"
    static let rectangleCornerRadiusKey = "ScreenshotAnnotation.rectangleCornerRadiusPoints"
    static let defaultRectangleCornerRadiusPoints = 4

    static func colorKey(for tool: ScreenshotAnnotationTool) -> String {
        "ScreenshotAnnotation.toolColor.\(tool.rawValue)"
    }

    static func defaultWidthKey(for tool: ScreenshotAnnotationTool) -> String {
        "ScreenshotAnnotation.toolWidth.\(tool.rawValue)"
    }

    static func defaultColor(for tool: ScreenshotAnnotationTool,
                             in defaults: UserDefaults = .standard) -> ScreenshotAnnotationColor {
        ScreenshotAnnotationColor(rawValue: defaults.integer(forKey: colorKey(for: tool))) ?? .red
    }

    static func rememberedWidthKey(for tool: ScreenshotAnnotationTool) -> String? {
        switch tool {
        case .rectangle: rectangleWidthKey
        case .discard: discardWidthKey
        case .ellipse: ellipseWidthKey
        case .brush: brushWidthKey
        case .pen: penWidthKey
        default: nil
        }
    }

    static func defaultWidth(for tool: ScreenshotAnnotationTool,
                             in defaults: UserDefaults = .standard) -> Double {
        let saved = defaults.object(forKey: defaultWidthKey(for: tool)) as? Double
        let remembered = rememberedWidthKey(for: tool).flatMap { key in
            remembers(in: defaults) ? defaults.object(forKey: key) as? Double : nil
        }
        let width = saved ?? remembered ?? tool.factoryWidth
        guard width.isFinite else { return tool.factoryWidth }
        return min(tool.widthRange.upperBound, max(tool.widthRange.lowerBound, width))
    }

    static func remembers(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: remembersToolAndStyleKey) as? Bool ?? true
    }

    static func startupTool(in defaults: UserDefaults = .standard) -> ScreenshotAnnotationTool {
        let choice = defaults.object(forKey: startupToolKey) as? Int
            ?? ScreenshotAnnotationTool.rectangle.rawValue
        if choice == rememberLastTool {
            return ScreenshotAnnotationTool(rawValue: defaults.integer(forKey: lastToolKey))
                ?? .rectangle
        }
        return ScreenshotAnnotationTool(rawValue: choice) ?? .rectangle
    }

    static func rectangleCornerRadiusPoints(in defaults: UserDefaults = .standard) -> CGFloat {
        guard defaults.object(forKey: rectangleCornerRadiusKey) != nil else {
            return CGFloat(defaultRectangleCornerRadiusPoints)
        }
        return CGFloat(min(24, max(1, defaults.integer(forKey: rectangleCornerRadiusKey))))
    }

    static func migrateDiscardStyle(in defaults: UserDefaults) {
        guard defaults.integer(forKey: rectangleStyleKey) == ScreenshotRectangleStyle.discard.rawValue else {
            return
        }
        defaults.set(ScreenshotRectangleStyle.roundedOutline.rawValue, forKey: rectangleStyleKey)
        if defaults.integer(forKey: lastToolKey) == ScreenshotAnnotationTool.rectangle.rawValue {
            defaults.set(ScreenshotAnnotationTool.discard.rawValue, forKey: lastToolKey)
        }
        if defaults.object(forKey: discardWidthKey) == nil,
           let previousWidth = defaults.object(forKey: rectangleWidthKey) {
            defaults.set(previousWidth, forKey: discardWidthKey)
        }
    }
}

enum ScreenshotAnnotationTool: Int, CaseIterable {
    // Keep existing raw values stable because the last selected tool is stored.
    case rectangle, ellipse, arrow, number, highlighter, mosaic, text, brush, spotlight, magnifier, pen, sticker
    case discard

    static let advancedTools: [Self] = [.sticker, .pen, .spotlight]
    static let toolsWithDefaultAppearance: [Self] = [
        .rectangle, .ellipse, .arrow, .text, .highlighter, .brush, .pen, .number, .discard
    ]

    var factoryWidth: Double {
        switch self {
        case .discard: 2
        case .highlighter: 18
        case .arrow, .text, .number: 0 // Preserve the existing automatic sizing.
        default: 4
        }
    }

    var widthRange: ClosedRange<Double> {
        switch self {
        case .arrow: 0...40
        case .text, .number: 0...6
        case .highlighter: 1...80
        default: 1...40
        }
    }

    var widthLabel: String {
        switch self {
        case .text: "文字描边线宽"
        case .number: "数字标记外圈线宽"
        default: "默认线宽"
        }
    }

    var supportsShapeConstraints: Bool { self == .rectangle || self == .ellipse || self == .discard }

    var hint: String {
        switch self {
        case .arrow: "拖动绘制箭头"
        case .text: "点击图片，输入文字后按回车"
        case .magnifier: "拖动绘制镜片；Shift 约束等宽高；蓝色菱形上下拖动调整倍数"
        case .mosaic: "拖动框选需要遮盖的区域"
        case .rectangle: "拖动绘制矩形；Shift 锁定单轴，Option 沿拖动方向绘制正方形"
        case .number: "连续点击放置数字标记；编号自动递增，撤销后回退"
        case .highlighter: "自由涂画；按住 Shift 从落笔点画直线"
        case .spotlight: "拖框保留区域亮度，压暗框外"
        case .ellipse: "拖动绘制椭圆；Shift 锁定单轴，Option 沿拖动方向绘制正圆"
        case .brush: "拖动自由绘制；按住 Shift 从落笔点画直线"
        case .discard: "拖动标记需要弃用的区域"
        case .pen: "单击加节点，拖动拉出曲线手柄；回车完成，点首节点闭合，Esc 取消路径"
        case .sticker: "从剪贴板或文件插入图片；拖动放置，之后可移动和缩放"
        }
    }

    var shortcutAction: AppShortcutAction? {
        switch self {
        case .rectangle: .annotationRectangle
        case .ellipse: .annotationEllipse
        case .text: .annotationText
        case .brush: .annotationBrush
        case .discard: .annotationDiscard
        case .arrow: .annotationArrow
        case .mosaic: .annotationMosaic
        case .pen: .annotationPen
        default: nil
        }
    }

    var icon: LucideSymbol {
        switch self {
        case .rectangle: .square
        case .number: .listOrdered
        case .highlighter: .highlighter
        case .ellipse: .circle
        case .arrow: .arrowUpRight
        case .mosaic: .grid3x3
        case .spotlight: .square
        case .text: .type
        case .magnifier: .zoomIn
        case .brush: .pencil
        case .discard: .squareX
        case .pen: .penTool
        case .sticker: .image
        }
    }

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .number: "数字标记"
        case .highlighter: "荧光笔"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .mosaic: "遮盖"
        case .spotlight: "区域高亮"
        case .text: "文字"
        case .magnifier: "放大镜"
        case .brush: "画笔"
        case .discard: "划除"
        case .pen: "钢笔"
        case .sticker: "贴图"
        }
    }
}

/// Keep directional resize cursors on Sonoma without referring to the
/// macOS 15 frame-resize enum outside its availability scope.
@MainActor
private enum ScreenshotResizeCursor {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .bottomRight: return Self.descending
        case .topRight, .bottomLeft: return Self.ascending
        }
    }

    private static let descending = diagonal("arrow.up.left.and.arrow.down.right")
    private static let ascending = diagonal("arrow.up.right.and.arrow.down.left")
    private static func diagonal(_ name: String) -> NSCursor {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return .crosshair
        }
        let image = NSImage(size: CGSize(width: 22, height: 22), flipped: false) { rect in
            symbol.draw(in: rect.insetBy(dx: 2, dy: 2))
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 11, y: 11))
    }
}

private enum ScreenshotAnnotationShadow {
    static func apply(width: CGFloat, in context: CGContext) {
        context.setShadow(offset: CGSize(width: 0, height: -width * 0.35),
                          blur: width * 0.8, color: NSColor.black.withAlphaComponent(0.14).cgColor)
    }
}

private enum ScreenshotRectangleStyle: Int, CaseIterable, Codable {
    case roundedOutline, roundedFilled, squareOutline, squareFilled
    // Preserve the saved style used by editable marks and copies created in build 339.
    case discard

    var title: String {
        switch self {
        case .roundedOutline: "圆角空心矩形（默认）"
        case .roundedFilled: "圆角实心矩形"
        case .squareOutline: "直角空心矩形"
        case .squareFilled: "直角实心矩形"
        case .discard: "划除"
        }
    }

    var isRounded: Bool { self == .roundedOutline || self == .roundedFilled || self == .discard }
    var isFilled: Bool { self == .roundedFilled || self == .squareFilled }
    var menuTitle: String { (isRounded ? "圆角" : "直角") + (isFilled ? "实心" : "空心") }

    func cornerRadius(in rect: CGRect, preferred radius: CGFloat) -> CGFloat {
        let shortSide = min(rect.width, rect.height)
        let preferredRadius = self == .discard ? max(radius, shortSide * 0.15) : radius
        return isRounded ? min(max(0, preferredRadius), shortSide / 2) : 0
    }

    private func framePath(in rect: CGRect, radius: CGFloat) -> CGPath {
        let corner = cornerRadius(in: rect, preferred: radius)
        return CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    func contains(_ point: CGPoint, in rect: CGRect, radius: CGFloat,
                  width: CGFloat, tolerance: CGFloat) -> Bool {
        let frame = framePath(in: rect, radius: radius)
        if isFilled { return frame.contains(point) }
        if self == .discard, frame.contains(point) { return true }
        return frame.copy(strokingWithWidth: max(width, tolerance * 2),
            lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point)
    }

    func draw(in rect: CGRect, radius: CGFloat, width: CGFloat, ink: NSColor, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let frame = framePath(in: rect, radius: radius)
        let isDiscard = self == .discard
        if !isDiscard { ScreenshotAnnotationShadow.apply(width: width, in: context) }
        if isFilled || isDiscard {
            let fill = isDiscard ? ink.withAlphaComponent(ink.alphaComponent * 0.08) : ink
            context.setFillColor(fill.cgColor)
            context.addPath(frame)
            context.fillPath()
            if isFilled { return }
        }
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        if isDiscard {
            // Composite the border and diagonals together so their joins stay even.
            context.setAlpha(0.8)
            context.beginTransparencyLayer(in: rect.insetBy(dx: -width, dy: -width),
                                           auxiliaryInfo: nil)
            // The border covers the clipped ends, including along rounded corners.
            context.saveGState()
            context.addPath(frame)
            context.clip()
            context.move(to: CGPoint(x: rect.minX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.strokePath()
            context.restoreGState()
        }
        context.addPath(frame)
        context.strokePath()
        if isDiscard { context.endTransparencyLayer() }
    }

    @MainActor var previewImage: NSImage {
        let image = NSImage(size: CGSize(width: 112, height: 42), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let rect = CGRect(x: 24, y: 7, width: 64, height: 28)
            draw(in: rect, radius: ScreenshotAnnotationPreferences.rectangleCornerRadiusPoints(),
                 width: 3.5, ink: .systemRed, context: context)
            return true
        }
        image.isTemplate = true
        return image
    }

}

private enum ScreenshotEllipseStyle: Int, CaseIterable, Codable {
    case outline, filled

    var title: String { self == .outline ? "空心椭圆（默认）" : "实心椭圆" }
    var isFilled: Bool { self == .filled }
    var menuTitle: String { isFilled ? "实心" : "空心" }

    func draw(in rect: CGRect, width: CGFloat, ink: NSColor, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        ScreenshotAnnotationShadow.apply(width: width, in: context)
        context.addEllipse(in: rect)
        if isFilled {
            context.setFillColor(ink.cgColor)
            context.fillPath()
        } else {
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }
    }

    @MainActor var previewImage: NSImage {
        let image = NSImage(size: CGSize(width: 112, height: 42), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: CGRect(x: 35, y: 5, width: 42, height: 32), width: 3.5, ink: .systemRed,
                 context: context)
            return true
        }
        image.isTemplate = true
        return image
    }
}

private enum ScreenshotMagnifierStyle: Int, CaseIterable, Codable {
    case ellipse, roundedRectangle

    var title: String { self == .ellipse ? "椭圆放大镜" : "圆角矩形放大镜" }
    var menuTitle: String { self == .ellipse ? "椭圆" : "圆角矩形" }

    func cornerRadius(in rect: CGRect) -> CGFloat {
        self == .ellipse ? 0 : min(12, min(rect.width, rect.height) * 0.12)
    }

    func path(in rect: CGRect, cornerRadius: CGFloat? = nil) -> CGPath {
        if self == .ellipse { return CGPath(ellipseIn: rect, transform: nil) }
        let radius = max(0, cornerRadius ?? self.cornerRadius(in: rect))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    func annotation(in rect: CGRect, magnification: CGFloat) -> ScreenshotAnnotation {
        self == .ellipse ? .ellipticalMagnifier(rect, magnification: magnification)
            : .rectangularMagnifier(rect, magnification: magnification)
    }

    @MainActor var previewImage: NSImage {
        let image = NSImage(size: CGSize(width: 112, height: 42), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let rect = CGRect(x: 24, y: 5, width: 64, height: 32)
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.06).cgColor)
            context.setStrokeColor(NSColor.labelColor.cgColor)
            context.setLineWidth(2)
            context.addPath(path(in: rect))
            context.drawPath(using: .fillStroke)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: 49, y: 21))
            context.addLine(to: CGPoint(x: 63, y: 21))
            context.move(to: CGPoint(x: 56, y: 14))
            context.addLine(to: CGPoint(x: 56, y: 28))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private enum ScreenshotArrowStyle: Int, CaseIterable, Codable {
    case rounded, sharp, bezier, withRectangle

    var menuTitle: String {
        switch self {
        case .rounded: "圆尾"
        case .sharp: "尖尾"
        case .bezier: "曲线"
        case .withRectangle: "箭头＋矩形"
        }
    }

    var title: String {
        switch self {
        case .rounded: "圆尾实心箭头（默认）"
        case .sharp: "尖尾实心箭头"
        case .bezier: "贝塞尔曲线箭头"
        case .withRectangle: "箭头＋矩形"
        }
    }

    @MainActor var previewImage: NSImage {
        let image = NSImage(size: CGSize(width: 112, height: 42), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if self == .withRectangle {
                let box = ScreenshotArrowBox(tail: CGPoint(x: 12, y: 7),
                    rect: CGRect(x: 65, y: 12, width: 35, height: 23),
                    arrowWidth: 3, arrowScale: 1, rectangleWidth: 2.5, rectangleRadius: 4)
                box.draw(ink: .systemRed, in: context)
                return true
            }
            let start = self == .bezier ? CGPoint(x: 12, y: 10) : CGPoint(x: 18, y: 21)
            let end = self == .bezier ? CGPoint(x: 100, y: 26) : CGPoint(x: 94, y: 21)
            let width: CGFloat = self == .bezier ? 3.8 : 3
            context.setFillColor(NSColor.systemRed.cgColor)
            let path = self == .bezier
                ? ScreenshotBezierArrowGeometry.path(
                    from: start, control: CGPoint(x: 54, y: 38), to: end,
                    minimumWidth: width
                )
                : ScreenshotArrowGeometry.path(from: start, to: end,
                                               style: self, shaftWidth: width)
            context.addPath(path)
            context.fillPath()
            if self == .bezier {
                let ring = ScreenshotBezierArrowGeometry.tailRing(
                    from: start, to: end, minimumWidth: width
                )
                context.setLineWidth(ring.strokeWidth)
                context.strokeEllipse(in: ring.rect)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

private enum ScreenshotArrowGeometry {
    /// A longer arrow needs a wider shaft as well as a larger head. Keep the
    /// canvas's pixel-scale width as the minimum for short arrows.
    static func effectiveShaftWidth(from start: CGPoint, to end: CGPoint,
                                    minimumWidth: CGFloat) -> CGFloat {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length.isFinite, length > 0.01,
              minimumWidth.isFinite, minimumWidth > 0 else { return 0 }
        return min(max(minimumWidth, length * 0.025), length * 0.1)
    }

    /// Build one filled silhouette in image coordinates for both the live
    /// draft and the final export. The start point is the tail, the end the tip.
    static func path(from start: CGPoint, to end: CGPoint,
                     style: ScreenshotArrowStyle, shaftWidth: CGFloat,
                     thicknessScale: CGFloat = 1) -> CGPath {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        let path = CGMutablePath()
        guard length.isFinite, length > 0.01, start.x.isFinite, start.y.isFinite,
              shaftWidth.isFinite, shaftWidth > 0 else { return path }
        let baseWidth = effectiveShaftWidth(from: start, to: end,
                                           minimumWidth: shaftWidth)
        let width = baseWidth * thicknessScale
        switch style {
        case .rounded, .withRectangle:
            let tailRadius = min(width / 2, max(shaftWidth * thicknessScale * 0.45, width * 0.16))
            let pixelScale = max(1, shaftWidth / 3)
            // The head grows more slowly than the full arrow. A linear head
            // length makes long annotations look like a huge triangle on a
            // thin line, even when the shaft itself tapers correctly.
            let baseHeadLength = min(length * 0.42,
                                     max(baseWidth * 3.6,
                                         2.6 * sqrt(length / pixelScale) * pixelScale))
            let headLength = min(length * 0.55, baseHeadLength * thicknessScale)
            let headHalfWidth = min(headLength * 0.5,
                                    max(width * 2, headLength * 0.4))
            let neckHalfWidth = max(tailRadius, min(width * 0.65, headHalfWidth * 0.42))
            let neck = length - headLength
            let vertices = [
                CGPoint(x: 0, y: tailRadius),
                CGPoint(x: neck, y: neckHalfWidth),
                CGPoint(x: neck, y: headHalfWidth),
                CGPoint(x: length, y: 0),
                CGPoint(x: neck, y: -headHalfWidth),
                CGPoint(x: neck, y: -neckHalfWidth),
                CGPoint(x: 0, y: -tailRadius)
            ]
            path.move(to: vertices[0])
            for index in 1..<(vertices.count - 1) {
                let previous = vertices[index - 1]
                let vertex = vertices[index]
                let next = vertices[index + 1]
                let incoming = hypot(previous.x - vertex.x, previous.y - vertex.y)
                let outgoing = hypot(next.x - vertex.x, next.y - vertex.y)
                let desiredTrim: CGFloat
                switch index {
                case 2, 4: // Round the two broad arrowhead shoulders.
                    desiredTrim = max(width * 0.85, headHalfWidth * 0.12)
                case 3: // Soften the tip without turning it into a flat end.
                    desiredTrim = max(width * 0.75, headLength * 0.05)
                default:
                    desiredTrim = width * 0.45
                }
                let trim = min(desiredTrim, incoming * 0.32, outgoing * 0.32)
                path.addLine(to: CGPoint(
                    x: vertex.x + (previous.x - vertex.x) * trim / incoming,
                    y: vertex.y + (previous.y - vertex.y) * trim / incoming
                ))
                path.addQuadCurve(to: CGPoint(
                    x: vertex.x + (next.x - vertex.x) * trim / outgoing,
                    y: vertex.y + (next.y - vertex.y) * trim / outgoing
                ), control: vertex)
            }
            path.addLine(to: vertices[vertices.count - 1])
            path.addArc(center: .zero, radius: tailRadius,
                        startAngle: -.pi / 2, endAngle: -.pi * 1.5, clockwise: true)
            path.closeSubpath()
        case .sharp:
            let baseHeadLength = min(length * 0.5, max(baseWidth * 8, length * 0.38))
            let headLength = min(length * 0.6, baseHeadLength * thicknessScale)
            let headHalfWidth = headLength * 0.52
            let neckHalfWidth = headHalfWidth * 0.32
            let neck = length - headLength * 0.76
            let shoulder = length - headLength
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: neck, y: neckHalfWidth))
            path.addLine(to: CGPoint(x: shoulder, y: headHalfWidth))
            path.addLine(to: CGPoint(x: length, y: 0))
            path.addLine(to: CGPoint(x: shoulder, y: -headHalfWidth))
            path.addLine(to: CGPoint(x: neck, y: -neckHalfWidth))
            path.closeSubpath()
        case .bezier:
            let control = ScreenshotBezierArrowGeometry.defaultControl(from: start, to: end)
            return ScreenshotBezierArrowGeometry.path(
                from: start, control: control, to: end, minimumWidth: shaftWidth,
                thicknessScale: thicknessScale
            )
        }
        var transform = CGAffineTransform(a: dx / length, b: dy / length,
                                         c: -dy / length, d: dx / length,
                                         tx: start.x, ty: start.y)
        return path.copy(using: &transform) ?? CGMutablePath()
    }

    static func draw(from start: CGPoint, to end: CGPoint, style: ScreenshotArrowStyle,
                     shaftWidth: CGFloat, thicknessScale: CGFloat = 1,
                     ink: NSColor, in context: CGContext) {
        let width = effectiveShaftWidth(from: start, to: end, minimumWidth: shaftWidth) * thicknessScale
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(ink.cgColor)
        ScreenshotAnnotationShadow.apply(width: width, in: context)
        context.addPath(path(from: start, to: end, style: style, shaftWidth: shaftWidth,
                             thicknessScale: thicknessScale))
        context.fillPath()
    }
}

private struct ScreenshotArrowBox: Codable {
    var tail: CGPoint
    var rect: CGRect
    var arrowWidth: CGFloat
    var arrowScale: CGFloat
    var rectangleWidth: CGFloat
    // Older editable combinations used square corners and saved no radius.
    var rectangleRadius: CGFloat? = nil

    static func targetRect(from start: CGPoint, to end: CGPoint, size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        var rect = CGRect(x: min(max(area.minX, end.x - width / 2), area.maxX - width),
                          y: min(max(area.minY, end.y - height / 2), area.maxY - height),
                          width: width, height: height)
        let dx = end.x - start.x
        let dy = end.y - start.y
        // For a short drag, leave room for the arrow on the start side.
        if abs(dx) >= abs(dy) {
            let middle = start.x + dx / 2
            if dx > 0, middle > rect.minX {
                rect = CGRect(x: middle, y: rect.minY, width: rect.maxX - middle, height: rect.height)
            } else if dx < 0, middle < rect.maxX {
                rect.size.width = middle - rect.minX
            }
        } else {
            let middle = start.y + dy / 2
            if dy > 0, middle > rect.minY {
                rect = CGRect(x: rect.minX, y: middle, width: rect.width, height: rect.maxY - middle)
            } else if dy < 0, middle < rect.maxY {
                rect.size.height = middle - rect.minY
            }
        }
        return rect
    }

    var radius: CGFloat {
        let preferred = rectangleRadius
            ?? CGFloat(ScreenshotAnnotationPreferences.defaultRectangleCornerRadiusPoints) * arrowWidth / 3
        return ScreenshotRectangleStyle.roundedOutline.cornerRadius(in: rect, preferred: preferred)
    }

    var connection: (tail: CGPoint, tip: CGPoint, corner: CGPoint) {
        let signX: CGFloat = tail.x <= rect.midX ? -1 : 1
        let signY: CGFloat = tail.y <= rect.midY ? -1 : 1
        let radius = self.radius
        let arcCenter = CGPoint(x: (signX < 0 ? rect.minX : rect.maxX) - signX * radius,
                                y: (signY < 0 ? rect.minY : rect.maxY) - signY * radius)
        let dx = (tail.x - arcCenter.x) * signX
        let dy = (tail.y - arcCenter.y) * signY
        let x = max(0, dx), y = max(0, dy)
        let distance = hypot(x, y)
        let normal: CGPoint
        if distance > 0 {
            normal = CGPoint(x: signX * x / distance, y: signY * y / distance)
        } else {
            normal = dx >= dy ? CGPoint(x: signX, y: 0) : CGPoint(x: 0, y: signY)
        }
        let corner = CGPoint(x: arcCenter.x + radius * normal.x,
                             y: arcCenter.y + radius * normal.y)
        let vx = tail.x - corner.x, vy = tail.y - corner.y
        let outward = vx * normal.x + vy * normal.y
        let sideways = abs(vx * normal.y - vy * normal.x)
        let gap = rectangleWidth / 2 + arrowWidth * 1.7
        // Keep the entire head outside the corner's tangent, even on a shallow approach.
        let clearance = max(outward, sideways * 0.6, gap + arrowWidth * 2)
        let visibleTail = CGPoint(x: tail.x + (clearance - outward) * normal.x,
                                  y: tail.y + (clearance - outward) * normal.y)
        let fraction = gap / clearance
        let tip = CGPoint(x: corner.x + (visibleTail.x - corner.x) * fraction,
                          y: corner.y + (visibleTail.y - corner.y) * fraction)
        return (visibleTail, tip, corner)
    }

    var arrowPath: CGPath {
        let arrow = connection
        return ScreenshotArrowGeometry.path(from: arrow.tail, to: arrow.tip, style: .rounded,
                                             shaftWidth: arrowWidth, thicknessScale: arrowScale)
    }

    func draw(ink: NSColor, in context: CGContext) {
        let arrow = connection
        ScreenshotArrowGeometry.draw(from: arrow.tail, to: arrow.tip, style: .rounded,
            shaftWidth: arrowWidth, thicknessScale: arrowScale, ink: ink, in: context)
        ScreenshotRectangleStyle.roundedOutline.draw(in: rect, radius: radius,
            width: rectangleWidth, ink: ink, context: context)
    }
}

private enum ScreenshotBezierArrowGeometry {
    static func defaultControl(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.01, length.isFinite else { return start }
        let bend = length * 0.23
        return CGPoint(x: (start.x + end.x) / 2 - dy / length * bend,
                       y: (start.y + end.y) / 2 + dx / length * bend)
    }

    static func tailRing(from start: CGPoint, to end: CGPoint,
                         minimumWidth: CGFloat,
                         thicknessScale: CGFloat = 1) -> (rect: CGRect, strokeWidth: CGFloat) {
        let baseWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
            from: start, to: end, minimumWidth: minimumWidth
        )
        let width = baseWidth * thicknessScale
        let radius = width * 0.72
        return (CGRect(x: start.x - radius, y: start.y - radius,
                       width: radius * 2, height: radius * 2),
                max(1.5, baseWidth * 0.24) * thicknessScale)
    }

    static func path(from start: CGPoint, control: CGPoint, to end: CGPoint,
                     minimumWidth: CGFloat, thicknessScale: CGFloat = 1) -> CGPath {
        let path = CGMutablePath()
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length.isFinite, length > 0.01,
              [start.x, start.y, control.x, control.y, end.x, end.y].allSatisfy(\.isFinite),
              minimumWidth.isFinite, minimumWidth > 0 else { return path }
        let baseWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
            from: start, to: end, minimumWidth: minimumWidth
        )
        let width = baseWidth * thicknessScale
        var tipDirection = CGPoint(x: end.x - control.x, y: end.y - control.y)
        var tipMagnitude = hypot(tipDirection.x, tipDirection.y)
        if tipMagnitude < 0.001 {
            tipDirection = CGPoint(x: end.x - start.x, y: end.y - start.y)
            tipMagnitude = length
        }
        tipDirection = CGPoint(x: tipDirection.x / tipMagnitude,
                               y: tipDirection.y / tipMagnitude)
        let headNormal = CGPoint(x: -tipDirection.y, y: tipDirection.x)
        let baseHeadLength = min(length * 0.32, max(baseWidth * 4.4, length * 0.18))
        let headLength = min(length * 0.48, baseHeadLength * thicknessScale)
        let baseHalfHead = min(baseHeadLength * 0.55,
                               max(baseWidth * 2.35, length * 0.055))
        let halfHead = baseHalfHead * thicknessScale
        let neck = CGPoint(x: end.x - tipDirection.x * headLength,
                           y: end.y - tipDirection.y * headLength)
        // Keep the head rigid. A point at a fixed parameter on the curved
        // shaft is generally not on the tip tangent, and using it as the
        // triangle's base shears the head when the middle handle is moved.
        // The cubic shaft preserves the start handle and joins the neck on
        // that same tangent, including when the handle reaches the tip.
        let firstControl = CGPoint(x: start.x + (control.x - start.x) * 2 / 3,
                                   y: start.y + (control.y - start.y) * 2 / 3)
        let endHandleLength = max(tipMagnitude * 2 / 3, headLength * 0.25, width)
        let secondControl = CGPoint(x: neck.x - tipDirection.x * endHandleLength,
                                    y: neck.y - tipDirection.y * endHandleLength)
        let polygonLength = hypot(firstControl.x - start.x, firstControl.y - start.y)
            + hypot(secondControl.x - firstControl.x, secondControl.y - firstControl.y)
            + hypot(neck.x - secondControl.x, neck.y - secondControl.y)
        guard polygonLength.isFinite else { return path }
        let steps = max(32, min(256, Int(min(256, polygonLength / 6))))
        let ring = tailRing(from: start, to: end, minimumWidth: minimumWidth,
                            thicknessScale: thicknessScale)
        let ringClearance = ring.rect.width / 2 + ring.strokeWidth / 2
        var startT: CGFloat = 1
        var travelled: CGFloat = 0
        var previous = start
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = position(t, start: start, firstControl: firstControl,
                                 secondControl: secondControl, end: neck)
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            if travelled + distance >= ringClearance {
                let fraction = min(1, max(0, (ringClearance - travelled) / max(0.001, distance)))
                startT = (CGFloat(step - 1) + fraction) / CGFloat(steps)
                break
            }
            travelled += distance
            previous = point
        }
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        for step in 0...steps {
            let t = startT + (1 - startT) * CGFloat(step) / CGFloat(steps)
            let point = position(t, start: start, firstControl: firstControl,
                                 secondControl: secondControl, end: neck)
            let normal = normal(t, start: start, firstControl: firstControl,
                                secondControl: secondControl, end: neck,
                                fallback: tipDirection)
            let progress = CGFloat(step) / CGFloat(steps)
            let halfWidth = width * (0.46 + progress * 0.28)
            upper.append(CGPoint(x: point.x + normal.x * halfWidth,
                                 y: point.y + normal.y * halfWidth))
            lower.append(CGPoint(x: point.x - normal.x * halfWidth,
                                 y: point.y - normal.y * halfWidth))
        }
        guard let first = upper.first else { return path }
        let wingX = headNormal.x * halfHead
        let wingY = headNormal.y * halfHead
        path.move(to: first)
        for point in upper.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: neck.x + wingX, y: neck.y + wingY))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: neck.x - wingX, y: neck.y - wingY))
        for point in lower.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private static func position(_ t: CGFloat, start: CGPoint, firstControl: CGPoint,
                                 secondControl: CGPoint, end: CGPoint) -> CGPoint {
        let inverse = 1 - t
        let a = inverse * inverse * inverse
        let b = 3 * inverse * inverse * t
        let c = 3 * inverse * t * t
        let d = t * t * t
        return CGPoint(x: a * start.x + b * firstControl.x + c * secondControl.x + d * end.x,
                       y: a * start.y + b * firstControl.y + c * secondControl.y + d * end.y)
    }

    private static func direction(_ t: CGFloat, start: CGPoint, firstControl: CGPoint,
                                  secondControl: CGPoint, end: CGPoint) -> CGPoint {
        let inverse = 1 - t
        return CGPoint(
            x: 3 * inverse * inverse * (firstControl.x - start.x)
                + 6 * inverse * t * (secondControl.x - firstControl.x)
                + 3 * t * t * (end.x - secondControl.x),
            y: 3 * inverse * inverse * (firstControl.y - start.y)
                + 6 * inverse * t * (secondControl.y - firstControl.y)
                + 3 * t * t * (end.y - secondControl.y))
    }

    private static func normal(_ t: CGFloat, start: CGPoint, firstControl: CGPoint,
                               secondControl: CGPoint, end: CGPoint, fallback: CGPoint) -> CGPoint {
        var tangent = direction(t, start: start, firstControl: firstControl,
                                secondControl: secondControl, end: end)
        var magnitude = hypot(tangent.x, tangent.y)
        if magnitude < 0.001 {
            tangent = fallback
            magnitude = 1
        }
        return CGPoint(x: -tangent.y / magnitude, y: tangent.x / magnitude)
    }
}

private enum ScreenshotTextStyle: Int, CaseIterable, Codable {
    // Keep the old raw values so previously saved editable screenshots reopen.
    case outlinedShadow, plain, subtitle, darkLabel, highlight, backgroundColor

    static let allCases: [Self] = [.plain, .outlinedShadow, .backgroundColor]

    var preferred: Self {
        switch self {
        case .subtitle: .outlinedShadow
        case .darkLabel, .highlight: .backgroundColor
        default: self
        }
    }

    var title: String {
        switch self {
        case .outlinedShadow: "描边"
        case .plain: "正常"
        case .backgroundColor: "背景色"
        case .subtitle: "白字字幕"
        case .darkLabel: "深色底牌"
        case .highlight: "荧光底牌"
        }
    }

    var foreground: NSColor {
        switch self {
        case .outlinedShadow, .plain, .backgroundColor: .systemRed
        case .subtitle, .darkLabel: .white
        case .highlight: NSColor(white: 0.08, alpha: 1)
        }
    }

    func background(for foreground: NSColor) -> NSColor? {
        switch self {
        case .backgroundColor:
            let color = foreground.usingColorSpace(.sRGB) ?? .red
            let tint: CGFloat = 0.08
            return NSColor(srgbRed: 1 - (1 - color.redComponent) * tint,
                           green: 1 - (1 - color.greenComponent) * tint,
                           blue: 1 - (1 - color.blueComponent) * tint, alpha: 1)
        case .darkLabel: return NSColor(white: 0.1, alpha: 0.92)
        case .highlight: return NSColor(red: 1, green: 0.88, blue: 0.25, alpha: 0.96)
        default: return nil
        }
    }

    func shadow(size: CGFloat) -> NSShadow? {
        guard self == .outlinedShadow || self == .subtitle else { return nil }
        let shadow = NSShadow()
        let outlined = self == .outlinedShadow
        shadow.shadowColor = NSColor.black.withAlphaComponent(outlined ? 0.15 : 0.28)
        shadow.shadowOffset = CGSize(width: 0, height: -size * (outlined ? 0.055 : 0.08))
        shadow.shadowBlurRadius = size * (outlined ? 0.15 : 0.12)
        return shadow
    }

    @MainActor func previewImage(color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 112, height: 42), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let size: CGFloat = 18
            let sample = self == .backgroundColor ? "123" : "文字"
            let rect = ScreenshotTextRendering.bounds(at: .zero, text: sample, size: size)
            context.saveGState()
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 112, height: 42),
                cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.clip()
            for (x, background) in [(CGFloat(0), NSColor.white), (56, NSColor(white: 0.10, alpha: 1))] {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(x: x, y: 0, width: 56, height: 42))
                ScreenshotTextRendering.draw(sample, at: CGPoint(x: x + (56 - rect.width) / 2,
                    y: (42 - rect.height) / 2 - rect.minY), size: size, style: self,
                    foregroundOverride: color, in: context)
            }
            context.restoreGState()
            return true
        }
    }
}

/// The editor and the exported image use the same font, baseline and effects.
/// Positions in the document always refer to the first glyph's baseline.
private enum ScreenshotTextRendering {
    static func font(size: CGFloat) -> NSFont {
        // Use a bundled macOS typeface with linear metrics for Chinese and
        // Latin text. The system UI font's optical sizes change glyph widths
        // between the editor's point size and the export's Retina pixel size.
        NSFont(name: "PingFangSC-Semibold", size: size) ?? legacyFont(size: size)
    }

    static func legacyFont(size: CGFloat) -> NSFont {
        NSFont(name: "HelveticaNeue-Bold", size: size) ?? .boldSystemFont(ofSize: size)
    }

    static func attributes(size: CGFloat, style: ScreenshotTextStyle,
                           includeShadow: Bool = true,
                           fontOverride: NSFont? = nil,
                           foregroundOverride: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        let foreground = foregroundOverride ?? style.foreground
        var attributes: [NSAttributedString.Key: Any] = [
            .font: fontOverride ?? font(size: size), .foregroundColor: foreground
        ]
        if style == .subtitle {
            attributes[.strokeWidth] = -1.8
            attributes[.strokeColor] = NSColor(white: 0.1, alpha: 1)
            if includeShadow, let shadow = style.shadow(size: size) {
                attributes[.shadow] = shadow
            }
        }
        return attributes
    }

    static func bounds(at point: CGPoint, text: String, size: CGFloat,
                       fontOverride: NSFont? = nil) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text.isEmpty ? "M" : text,
            attributes: [.font: fontOverride ?? font(size: size)]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return CGRect(x: point.x, y: point.y - descent,
                      width: max(1, width), height: max(1, ascent + descent))
    }

    static func backgroundRect(_ bounds: CGRect, size: CGFloat) -> CGRect {
        bounds.insetBy(dx: -size * 0.3, dy: -size * 0.18)
    }

    static func drawBackground(_ bounds: CGRect, size: CGFloat, style: ScreenshotTextStyle,
                               foreground: NSColor, in context: CGContext) {
        guard let background = style.background(for: foreground) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if style == .backgroundColor {
            context.setShadow(offset: CGSize(width: 0, height: -size * 0.045), blur: size * 0.13,
                              color: NSColor.black.withAlphaComponent(0.09).cgColor)
        }
        context.setFillColor(background.cgColor)
        context.addPath(CGPath(roundedRect: backgroundRect(bounds, size: size),
                              cornerWidth: size * 0.18, cornerHeight: size * 0.18,
                              transform: nil))
        context.fillPath()
    }

    static func drawOutline(_ text: String, at point: CGPoint, size: CGFloat,
                            foreground: NSColor, fontOverride: NSFont? = nil,
                            outlineWidth: CGFloat? = nil,
                            in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let outline = foreground == .white ? NSColor(white: 0.1, alpha: 1) : .white
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: fontOverride ?? font(size: size),
            .foregroundColor: outline,
            .strokeColor: outline,
            .strokeWidth: outlineWidth.map { -100 * $0 / max(1, size) } ?? -16.0
        ]))
        if let shadow = ScreenshotTextStyle.outlinedShadow.shadow(size: size) {
            context.setShadow(offset: shadow.shadowOffset, blur: shadow.shadowBlurRadius,
                              color: shadow.shadowColor?.cgColor)
        }
        context.setLineJoin(.round)
        // Cast one shadow from the filled outline silhouette so adjacent
        // glyphs and the inner edges of their strokes don't darken each other.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
        context.endTransparencyLayer()
    }

    static func draw(_ text: String, at point: CGPoint, size: CGFloat,
                     style: ScreenshotTextStyle, fontOverride: NSFont? = nil,
                     foregroundOverride: NSColor? = nil, outlineWidth: CGFloat? = nil,
                     in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        drawBackground(bounds(at: point, text: text, size: size, fontOverride: fontOverride), size: size,
                       style: style, foreground: foregroundOverride ?? style.foreground, in: context)
        if style == .outlinedShadow {
            // Fill over the outline so a thick edge cannot eat into the glyph.
            drawOutline(text, at: point, size: size, foreground: foregroundOverride ?? style.foreground,
                        fontOverride: fontOverride, outlineWidth: outlineWidth, in: context)
        } else if let shadow = style.shadow(size: size) {
            context.setShadow(offset: shadow.shadowOffset, blur: shadow.shadowBlurRadius,
                              color: shadow.shadowColor?.cgColor)
        }
        let textAttributes = attributes(size: size, style: style, includeShadow: false,
                                        fontOverride: fontOverride, foregroundOverride: foregroundOverride)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: textAttributes))
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }
}

enum ScreenshotAnnotationColor: Int, CaseIterable, Codable {
    case red, orange, gold, green, teal, blue, violet, graphite, white

    var title: String {
        switch self {
        case .red: "朱红"
        case .orange: "珊瑚橙"
        case .gold: "琥珀黄"
        case .green: "翡翠绿"
        case .teal: "湖水青"
        case .blue: "钴蓝"
        case .violet: "鸢尾紫"
        case .graphite: "石墨黑"
        case .white: "白色"
        }
    }

    var color: NSColor {
        let rgb: UInt32
        switch self {
        case .red: return .systemRed
        case .white: return .white
        case .orange: rgb = 0xF26A35
        case .gold: rgb = 0xE9A500
        case .green: rgb = 0x2DAA67
        case .teal: rgb = 0x089A9E
        case .blue: rgb = 0x3675ED
        case .violet: rgb = 0x9158D9
        case .graphite: rgb = 0x263141
        }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    @MainActor var toolbarPalette: NSImage {
        func hex(_ color: NSColor) -> String {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                          Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        var outline = hex(.labelColor)
        NSApp?.effectiveAppearance.performAsCurrentDrawingAppearance { outline = hex(.labelColor) }
        let body = "M12 3.25a8.75 8.75 0 0 0 0 17.5c2.15 0 3-1.5 2-3.15-.45-.75.1-1.7 1-1.7h1.2c2.85 0 4.55-1.7 4.55-4.15C20.75 7 16.83 3.25 12 3.25Z"
        // Even-odd subpaths cut actual holes instead of painting white dots.
        let holes = "M8.5 10a1.25 1.25 0 1 0 -2.5 0a1.25 1.25 0 1 0 2.5 0Z M13.25 6.9a1.25 1.25 0 1 0 -2.5 0a1.25 1.25 0 1 0 2.5 0Z M17.75 9.4a1.25 1.25 0 1 0 -2.5 0a1.25 1.25 0 1 0 2.5 0Z"
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
          <path d="\(body) \(holes)" fill="\(hex(color))" fill-rule="evenodd"/>
          <path d="\(body)" fill="none" stroke="\(outline)" stroke-width="2.16" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """
        return NSImage(data: Data(svg.utf8)) ?? swatch
    }

    var swatch: NSImage {
        swatch(size: 18)
    }

    func swatch(size: CGFloat, selected: Bool = false) -> NSImage {
        NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2),
                                    xRadius: 4, yRadius: 4)
            color.setFill()
            tile.fill()
            NSColor.secondaryLabelColor.setStroke()
            tile.stroke()
            if selected {
                let check = NSBezierPath()
                check.move(to: CGPoint(x: size * 0.28, y: size * 0.48))
                check.line(to: CGPoint(x: size * 0.44, y: size * 0.32))
                check.line(to: CGPoint(x: size * 0.73, y: size * 0.64))
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                (self == .white || self == .gold ? NSColor.black : .white).setStroke()
                check.stroke()
            }
            return true
        }
    }

    @MainActor func menuSwatch() -> NSImage {
        NSImage(size: CGSize(width: 28, height: 28), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let tile = RoundedRectangle(cornerRadius: 8, style: .continuous)
                .path(in: rect.insetBy(dx: 1, dy: 1)).cgPath
            context.addPath(tile)
            context.setFillColor(color.cgColor)
            context.fillPath()
            context.addPath(tile)
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(self == .white ? 0.25 : 0.12).cgColor)
            context.setLineWidth(0.8)
            context.strokePath()
            return true
        }
    }

    @MainActor var toolbarColorSwatch: NSImage {
        NSImage(size: CGSize(width: 24, height: 24), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let tile = RoundedRectangle(cornerRadius: 6, style: .continuous)
                .path(in: rect.insetBy(dx: 2.5, dy: 2.5)).cgPath
            context.addPath(tile)
            context.setFillColor(color.cgColor)
            context.fillPath()
            context.addPath(tile)
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.28).cgColor)
            context.setLineWidth(1)
            context.strokePath()
            return true
        }
    }

    @MainActor func highlighterPreview(opacity: Int) -> NSImage {
        NSImage(size: CGSize(width: 112, height: 42), flipped: false) { _ in
            let background = NSBezierPath()
            for y: CGFloat in [12, 21, 30] {
                background.move(to: CGPoint(x: 18, y: y))
                background.line(to: CGPoint(x: 94, y: y))
            }
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
            background.lineWidth = 1.5
            background.stroke()
            let stroke = NSBezierPath()
            stroke.move(to: CGPoint(x: 22, y: 15))
            stroke.curve(to: CGPoint(x: 90, y: 27),
                         controlPoint1: CGPoint(x: 40, y: 25),
                         controlPoint2: CGPoint(x: 66, y: 17))
            color.withAlphaComponent(CGFloat(opacity) / 100).setStroke()
            stroke.lineWidth = 13
            stroke.lineCapStyle = .round
            stroke.stroke()
            return true
        }
    }
}

private enum ScreenshotObscureMode: Int, CaseIterable, Codable {
    case blur, mosaic

    var title: String { self == .blur ? "背景模糊" : "马赛克" }

    @MainActor private static let previewContext = CIContext(options: [.useSoftwareRenderer: true])

    @MainActor func previewImage(strength: Int) -> NSImage {
        let size = CGSize(width: 112, height: 42)
        let source = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (index, color) in [NSColor.systemBlue, .systemOrange, .systemTeal].enumerated() {
                color.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: CGRect(x: 6 + index * 35, y: 5, width: 31, height: 32),
                             xRadius: 4, yRadius: 4).fill()
            }
            ("Aa" as NSString).draw(at: CGPoint(x: 37, y: 7), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 23), .foregroundColor: NSColor.black
            ])
            return true
        }
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        let input = CIImage(cgImage: cgImage)
        let level = min(5, max(1, strength)) - 1
        let output: CIImage
        if self == .blur {
            output = input.clampedToExtent().applyingGaussianBlur(sigma: [0.8, 1.3, 2.3, 3.5, 5][level])
        } else {
            output = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: [3, 5, 7, 10, 14][level]])
        }
        guard let result = Self.previewContext.createCGImage(output, from: input.extent) else { return source }
        return NSImage(cgImage: result, size: size)
    }
}

/// Control points are absolute image coordinates. Moving an anchor carries
/// its two controls; dragging a control changes the tangent independently.
private struct ScreenshotPenNode: Codable, Equatable {
    var point: CGPoint
    var incoming: CGPoint?
    var outgoing: CGPoint?

    func map(_ transform: (CGPoint) -> CGPoint) -> Self {
        Self(point: transform(point), incoming: incoming.map(transform), outgoing: outgoing.map(transform))
    }
}

private enum ScreenshotPenGeometry {
    static func path(_ nodes: [ScreenshotPenNode], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = nodes.first else { return path }
        path.move(to: first.point)
        func segment(_ from: ScreenshotPenNode, _ to: ScreenshotPenNode) {
            if from.outgoing != nil || to.incoming != nil {
                path.addCurve(to: to.point, control1: from.outgoing ?? from.point,
                              control2: to.incoming ?? to.point)
            } else { path.addLine(to: to.point) }
        }
        for pair in zip(nodes, nodes.dropFirst()) { segment(pair.0, pair.1) }
        if closed, nodes.count > 2 { segment(nodes[nodes.count - 1], first); path.closeSubpath() }
        return path
    }
}

private struct ScreenshotStickerAsset: Codable {
    let id: UUID
    let pngData: Data
    let width: Int
    let height: Int

    @MainActor static func decode(_ data: Data) -> Self? {
        guard data.count <= 64 * 1024 * 1024 else { return nil }
        let image: CGImage
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceCreateThumbnailWithTransform: true
           ] as CFDictionary) { image = thumbnail }
        else {
            // AppKit's SVG image representation renders vector inputs natively.
            guard let vector = NSImage(data: data), vector.size.width.isFinite,
                  vector.size.height.isFinite, vector.size.width > 0, vector.size.height > 0 else { return nil }
            let scale = min(1, 4096 / max(vector.size.width, vector.size.height))
            let size = CGSize(width: max(1, ceil(vector.size.width * scale)),
                              height: max(1, ceil(vector.size.height * scale)))
            guard let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            vector.draw(in: CGRect(origin: .zero, size: size), from: .zero,
                        operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let rendered = bitmap.makeImage() else { return nil }
            image = rendered
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              png.count <= 32 * 1024 * 1024 else { return nil }
        return Self(id: UUID(), pngData: png, width: image.width, height: image.height)
    }

    @MainActor static func fromPasteboard(_ board: NSPasteboard) -> Self? {
        for type in [NSPasteboard.PasteboardType.png, .tiff, .init("public.svg-image"), .init("public.jpeg")] {
            if let data = board.data(forType: type), let asset = decode(data) { return asset }
        }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls.prefix(10) {
                if let asset = fromFile(url) { return asset }
            }
        }
        return nil
    }

    @MainActor static func fromFile(_ url: URL) -> Self? {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 64 * 1024 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return decode(data)
    }
}

private enum ScreenshotAnnotation: Codable {
    indirect case colored(ScreenshotAnnotation, ScreenshotAnnotationColor)
    case obscure(CGRect, mode: ScreenshotObscureMode, strength: Int)
    case arrow(CGPoint, CGPoint, style: ScreenshotArrowStyle, width: CGFloat)
    case bezierArrow(start: CGPoint, control: CGPoint, end: CGPoint, width: CGFloat)
    case sizedArrow(CGPoint, CGPoint, style: ScreenshotArrowStyle, width: CGFloat, scale: CGFloat)
    case sizedBezierArrow(start: CGPoint, control: CGPoint, end: CGPoint, width: CGFloat, scale: CGFloat)
    case arrowBox(ScreenshotArrowBox)
    case text(CGPoint, String, fontSize: CGFloat)
    // Retain the original text case to read existing editable screenshots.
    case styledText(CGPoint, String, fontSize: CGFloat, style: ScreenshotTextStyle,
                    outlineWidth: CGFloat? = nil)
    case mosaic(CGRect)
    case rectangle(CGRect)
    case filledRectangle(CGRect)
    case styledRectangle(CGRect, style: ScreenshotRectangleStyle, width: CGFloat)
    case styledRectangleWithRadius(CGRect, style: ScreenshotRectangleStyle,
                                   width: CGFloat, radius: CGFloat)
    case number(CGPoint, Int, CGFloat, borderWidth: CGFloat? = nil)
    case highlighter([CGPoint], CGFloat, opacity: Int? = nil)
    case spotlight(CGRect)
    case magnifier(center: CGPoint, radius: CGFloat)
    // Keep the circular case above to read previously saved images.
    case ellipticalMagnifier(CGRect, magnification: CGFloat)
    case rectangularMagnifier(CGRect, magnification: CGFloat)
    case brush([CGPoint], CGFloat)
    case pen([ScreenshotPenNode], width: CGFloat, closed: Bool)
    case sticker(CGRect, ScreenshotStickerAsset)
    case ellipse(CGRect)
    case styledEllipse(CGRect, style: ScreenshotEllipseStyle, width: CGFloat)
    case translation([ScreenshotTranslatedLine])

    var shape: ScreenshotAnnotation {
        if case .colored(let item, _) = self { return item.shape }
        return self
    }

    var color: ScreenshotAnnotationColor? {
        if case .colored(_, let color) = self { return color }
        return nil
    }

    func colored(_ color: ScreenshotAnnotationColor?) -> ScreenshotAnnotation {
        guard let color else { return shape }
        return .colored(shape, color)
    }

    var magnifierGeometry: (rect: CGRect, magnification: CGFloat, style: ScreenshotMagnifierStyle)? {
        switch shape {
        case .magnifier(let center, let radius):
            return (CGRect(x: center.x - radius, y: center.y - radius,
                           width: radius * 2, height: radius * 2), 2, .ellipse)
        case .ellipticalMagnifier(let rect, let magnification):
            return (rect.standardized, min(8, max(1, magnification)), .ellipse)
        case .rectangularMagnifier(let rect, let magnification):
            return (rect.standardized, min(8, max(1, magnification)), .roundedRectangle)
        default: return nil
        }
    }
}

private struct ScreenshotTranslatedLine: Codable {
    var sourceRect: CGRect
    var text: String
    var fontSize: CGFloat? = nil
}

private enum ScreenshotTranslationLayout {
    static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = size * 0.12
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String):
                CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String):
                NSColor.black.cgColor,
            .paragraphStyle: paragraph
        ])
    }

    static func padding(for size: CGFloat) -> CGFloat { max(1, size * 0.1) }

    static func measured(_ text: String, size: CGFloat, width: CGFloat) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text, size: size))
        return CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
            CGSize(width: max(1, width - padding(for: size) * 2), height: 1_000_000), nil)
    }

    static func fittedFont(_ text: String, preferred: CGFloat, in rect: CGRect) -> CGFloat {
        func fits(_ size: CGFloat) -> Bool {
            let measured = measured(text, size: size, width: rect.width)
            return ceil(measured.height) + padding(for: size) * 2 <= rect.height
        }
        if fits(preferred) { return preferred }
        var low: CGFloat = 1
        var high = preferred
        for _ in 0..<14 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }

    /// Use the free space beside/below each OCR line before reducing its font.
    /// Coordinates stay in source pixels so preview zoom never affects export.
    static func arrange(_ lines: [ScreenshotTranslatedLine], imageSize: CGSize,
                        pixelsPerPoint: CGFloat) -> [ScreenshotTranslatedLine] {
        let full = CGRect(origin: .zero, size: imageSize)
        let gap = max(1, pixelsPerPoint * 2)
        return lines.enumerated().map { index, line in
            let source = line.sourceRect.intersection(full)
            guard source.width > 0, source.height > 0 else { return line }
            let preferred = min(72 * pixelsPerPoint,
                                max(14 * pixelsPerPoint, source.height * 1.15))
            let sameRow = lines.enumerated().filter { otherIndex, other in
                otherIndex != index && other.sourceRect.minX >= source.maxX - 1
                    && other.sourceRect.minY < source.maxY
                    && other.sourceRect.maxY > source.minY
            }.map { $0.element.sourceRect.minX - gap }
            let right = max(source.maxX, min(full.maxX, sameRow.min() ?? full.maxX))
            let oneLine = CTLineCreateWithAttributedString(attributed(line.text, size: preferred))
            let desiredWidth = ceil(CGFloat(CTLineGetTypographicBounds(oneLine, nil, nil, nil)))
                + padding(for: preferred) * 2
            let width = max(source.width, min(right - source.minX, desiredWidth))
            let nextRows = lines.enumerated().filter { otherIndex, other in
                otherIndex != index && other.sourceRect.minY >= source.maxY - 1
                    && other.sourceRect.maxX > source.minX
                    && other.sourceRect.minX < source.minX + width
            }.map { $0.element.sourceRect.minY - gap }
            let bottom = max(source.maxY, min(full.maxY, nextRows.min() ?? full.maxY))
            let available = CGRect(x: source.minX, y: source.minY,
                                   width: width, height: bottom - source.minY)
            let font = fittedFont(line.text, preferred: preferred, in: available)
            let height = max(source.height, min(available.height,
                ceil(measured(line.text, size: font, width: width).height)
                    + padding(for: font) * 2))
            return ScreenshotTranslatedLine(sourceRect: CGRect(
                x: source.minX, y: source.minY, width: width, height: height),
                text: line.text, fontSize: font)
        }
    }

    static func draw(_ line: ScreenshotTranslatedLine, size: CGFloat,
                     rect: CGRect, in context: CGContext) {
        let frame = rect.insetBy(dx: padding(for: size), dy: padding(for: size))
        guard frame.width > 0, frame.height > 0 else { return }
        context.saveGState()
        context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        context.fill(rect)
        context.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(line.text, size: size))
        let textFrame = CTFramesetterCreateFrame(framesetter, CFRange(),
            CGPath(rect: frame, transform: nil), nil)
        CTFrameDraw(textFrame, context)
        context.restoreGState()
    }
}

private struct ScreenshotAnnotationDocument: Codable {
    static let supportedVersions = 1...10
    let version: Int
    let imageWidth: Int
    let imageHeight: Int
    let annotations: [ScreenshotAnnotation]
}

private enum ScreenshotCropGeometry {
    /// The canvas uses bottom-left pixel coordinates; CGImage cropping uses top-left.
    static func pixelRect(_ proposed: CGRect, in size: CGSize) -> CGRect? {
        guard [proposed.minX, proposed.minY, proposed.width, proposed.height].allSatisfy(\.isFinite),
              proposed.width > 0, proposed.height > 0 else { return nil }
        let clipped = proposed.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped.integral.intersection(CGRect(origin: .zero, size: size))
    }
}

struct ScreenshotEditPayload {
    let baseImageData: Data
    let annotationData: Data
}

private struct ScreenshotTextMessageView: View {
    let title: String
    let detail: String
    let isLoading: Bool
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if isLoading { ProgressView() }
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(isLoading ? Color.secondary : Color.orange)
            if let onRetry { Button("重新识别", action: onRetry) }
        }
        .frame(width: 398, alignment: .leading)
        .padding(16)
    }
}

private struct ScreenshotOCRResultView: View {
    let text: String
    let onCopy: (String) -> Bool
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("识别文字").font(.system(size: 15, weight: .semibold))
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(240, max(90, CGFloat(text.count / 38 + 1) * 20)))
            HStack {
                Text("从当前截图识别；图片尚未存入历史")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(didCopy ? "已复制" : "复制文字") {
                    didCopy = onCopy(text)
                }
            }
        }
        .font(.system(size: 13))
        .frame(width: 398)
        .padding(16)
    }
}

private struct ScreenshotClipboardImagePicker: View {
    @ObservedObject var model: AppController
    let onSelect: (ClipboardEntry) -> String?
    let onCancel: () -> Void
    @State private var query = ""
    @State private var error: String?

    private var entries: [ClipboardEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.annotationImageEntries.filter { entry in
            query.isEmpty || [entry.fileName, entry.sourceAppName, entry.title].compactMap { $0 }
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择剪贴板图片").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(entries.count) 张").font(.caption).foregroundStyle(.secondary)
            }
            TextField("搜索图片名称或来源应用", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                if entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(query.isEmpty ? "剪贴板历史中还没有图片" : "没有找到匹配的图片")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 126, maximum: 160), spacing: 12)], spacing: 12) {
                        ForEach(entries) { entry in
                            Button { error = onSelect(entry) } label: {
                                ScreenshotClipboardImageCell(model: model, entry: entry)
                            }
                            .buttonStyle(.plain)
                            .help("选择\(entry.fileName ?? entry.title)")
                        }
                    }.padding(2)
                }
            }
            HStack {
                Text(error ?? "选择图片后，回到截图拖动放置")
                    .font(.caption).foregroundStyle(error == nil ? Color.secondary : .orange)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 430)
    }
}

private struct ScreenshotClipboardImageCell: View {
    let model: AppController
    let entry: ClipboardEntry
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().padding(5) }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(height: 92)
            Text(entry.fileName ?? entry.sourceAppName ?? "图片").font(.system(size: 11)).lineLimit(1)
            Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .task(id: entry.id) { thumbnail = await model.annotationImageThumbnail(for: entry) }
    }
}

/// Mounted only when a selected language pair needs a system download.
/// The framework owns the download confirmation; the result stays on the
/// screenshot canvas rather than appearing in a translation result window.
@available(macOS 15.0, *)
private struct ScreenshotTranslationDownloadView: View {
    let source: Locale.Language
    let target: Locale.Language
    let requests: [TranslationSession.Request]
    let onComplete: @MainActor (Result<[TranslationSession.Response], Error>) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(source: source, target: target) { session in
                do {
                    let responses = try await session.translations(from: requests)
                    await MainActor.run { onComplete(.success(responses)) }
                } catch {
                    await MainActor.run { onComplete(.failure(error)) }
                }
            }
    }
}

/// The canvas stores every shape in original image coordinates. Resizing the
/// editor changes only the preview, not the exported screenshot resolution.
@MainActor
private final class ScreenshotAnnotationCanvas: NSView, NSTextFieldDelegate {
    private final class StrokeHintField: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private(set) var image: CGImage
    private var hasImageEdits = false
    private let obscuredImages = NSCache<NSNumber, CGImage>()
    private let stickerImages = NSCache<NSUUID, CGImage>()
    private lazy var blurContext = CIContext(options: [.cacheIntermediates: false])
    private var toolColors: [ScreenshotAnnotationTool: ScreenshotAnnotationColor] = [:]
    var annotationColor: ScreenshotAnnotationColor { toolColors[tool] ?? .red }
    private(set) var obscureMode: ScreenshotObscureMode = .blur
    private var obscureStrengths: [ScreenshotObscureMode: Int] = [:]
    var obscureStrength: Int { obscureStrengths[obscureMode] ?? 3 }
    private let contentInset: CGFloat
    private var scanOverlay: ScanLoadingView?
    var scanMessage: String? {
        didSet {
            guard let scanMessage else {
                scanOverlay?.removeFromSuperview()
                scanOverlay = nil
                return
            }
            let overlay = scanOverlay ?? ScanLoadingView(frame: imageRect)
            overlay.message = scanMessage
            if scanOverlay == nil { addSubview(overlay); scanOverlay = overlay }
            needsLayout = true
        }
    }
    var tool: ScreenshotAnnotationTool = .rectangle { didSet {
        cancelDraft()
        if tool != .sticker { pendingSticker = nil }
    } }
    var arrowStyle: ScreenshotArrowStyle = .rounded { didSet { needsDisplay = true } }
    var rectangleStyle: ScreenshotRectangleStyle = .roundedOutline { didSet { needsDisplay = true } }
    var ellipseStyle: ScreenshotEllipseStyle = .outline { didSet { needsDisplay = true } }
    var magnifierStyle: ScreenshotMagnifierStyle = .ellipse { didSet { needsDisplay = true } }
    var textStyle: ScreenshotTextStyle = .outlinedShadow
    var arrowThicknessScale: CGFloat = 1
    private var arrowLineWidthPoints: CGFloat = 0
    var rectangleLineWidthPoints: CGFloat = 4
    var discardLineWidthPoints = CGFloat(ScreenshotAnnotationTool.discard.factoryWidth)
    var ellipseLineWidthPoints: CGFloat = 4
    var brushLineWidthPoints: CGFloat = 4
    var penLineWidthPoints: CGFloat = 4
    private var highlighterLineWidthPoints = CGFloat(ScreenshotAnnotationTool.highlighter.factoryWidth)
    private var textOutlineWidthPoints: CGFloat = 0
    private var numberBorderWidthPoints: CGFloat = 0
    private(set) var magnifierMagnification: CGFloat = 2
    var rectangleCornerRadiusPoints: CGFloat = CGFloat(
        ScreenshotAnnotationPreferences.defaultRectangleCornerRadiusPoints)
    var strokePixelsPerPoint: CGFloat = max(1, NSScreen.main?.backingScaleFactor ?? 2)
    var onStrokePreferenceChanged: ((ScreenshotAnnotationTool, CGFloat) -> Void)?
    var onChange: (() -> Void)?
    var onImageSizeChanged: (() -> Void)?
    var onCropChanged: (() -> Void)?
    var isInputSuspended = false
    var onDoubleClick: (() -> Void)?
    var onTextEditingChanged: (() -> Void)?
    var onElementClipboardChanged: (() -> Void)?
    private var penNodes: [ScreenshotPenNode] = []
    private var penRedoNodes: [ScreenshotPenNode] = []
    private var penDraggedNode: Int?
    private var penColor: ScreenshotAnnotationColor?
    private var penWidth: CGFloat = 4
    var pendingSticker: ScreenshotStickerAsset? { didSet { needsDisplay = true } }
    var onSelectionChanged: ((CGRect, Bool, Bool) -> Void)?
    var isAdjustingSelection = false { didSet { needsDisplay = true } }
    private(set) var annotations: [ScreenshotAnnotation] = []
    private struct Snapshot {
        let image: CGImage
        let annotations: [ScreenshotAnnotation]
        let hasImageEdits: Bool
    }
    private var snapshot: Snapshot {
        Snapshot(image: image, annotations: annotations, hasImageEdits: hasImageEdits)
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private(set) var isCropping = false
    private(set) var cropRect: CGRect?
    private var cropHasSelection = false
    private var cropDragHandle: SelectionDrag?
    private var cropStartPoint: CGPoint?
    private var cropStartRect = CGRect.zero
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    private var dragModifiers: NSEvent.ModifierFlags = []
    private enum ConstraintAxis { case horizontal, vertical }
    private var constraintAxis: ConstraintAxis?
    private var fixedOppositeDimension: CGFloat?
    private var strokeGestureIndex: Int?
    private var strokeGestureTime: TimeInterval = 0
    private var strokeHint: NSTextField?
    private var strokeHintTask: DispatchWorkItem?
    private enum BezierHandle { case start, control, end }
    private var activeBezierIndex: Int?
    private enum ElementHandle: Equatable {
        case body, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case start, control, end
        case magnification
        case pathAnchor(Int), pathIncoming(Int), pathOutgoing(Int)
    }
    private struct ElementHit {
        let index: Int
        let handle: ElementHandle
        let translationLine: Int?
    }
    private struct ElementDrag {
        let hit: ElementHit
        let original: ScreenshotAnnotation
        let start: CGPoint
        let before: [ScreenshotAnnotation]
        let duplicates: Bool
    }
    var onSelectedElementChanged: (() -> Void)?
    private var selectedIndex: Int? { didSet { onSelectedElementChanged?() } }
    private var hoveredIndex: Int?
    private var elementDrag: ElementDrag?
    private var elementDragChanged = false
    private var elementDragCopyIndex: Int?
    static let elementPasteboardType = NSPasteboard.PasteboardType("com.renzhenglin.cliphoook.annotation-element")
    private var lastElementPasteboard: NSPasteboard.Name?
    private var lastElementPasteboardChange = -1
    private var elementPasteCount = 0
    private var highlighterPoints: [CGPoint] = []
    private var highlighterWidth: CGFloat = 20
    private(set) var highlighterOpacity = 50
    private var brushPoints: [CGPoint] = []
    private var brushWidth: CGFloat = 4
    private var activeTextField: NSTextField?
    private weak var observedTextInputEditor: NSTextView?
    private weak var observedTextInputStorage: NSTextStorage?
    private var pendingTextInputRefresh: DispatchWorkItem?
    private var textLocation: CGPoint?
    private var textFontSize: CGFloat = 32
    private var editingTextStyle: ScreenshotTextStyle = .outlinedShadow
    private var editingColor: ScreenshotAnnotationColor?
    private var editingOutlineWidth: CGFloat?

    private var drawingColor: ScreenshotAnnotationColor? {
        annotationColor == .red && tool != .highlighter ? nil : annotationColor
    }
    private var editingLegacyText = false
    private var editingTextIndex: Int?
    private var editingTranslationLine: Int?
    private var mouseTrackingArea: NSTrackingArea?
    private enum SelectionDrag: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

        var adjustsLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var adjustsRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var adjustsTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var adjustsBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

        @MainActor var resizeCursor: NSCursor? {
            let position: ScreenshotResizeCursor
            switch self {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            case .move: return nil
            }
            return position.cursor
        }
    }
    static let handleHitRadius: CGFloat = 18
    private var selectionDrag: SelectionDrag?
    private var selectionStartFrame = CGRect.zero
    private var selectionStartPoint = CGPoint.zero
    private var selectionLastPoint = CGPoint.zero
    private var selectionConstraintHorizontal: Bool?

    init(image: CGImage, contentInset: CGFloat = 20) {
        self.image = image
        obscuredImages.totalCostLimit = 96 * 1024 * 1024
        stickerImages.totalCostLimit = 96 * 1024 * 1024
        self.contentInset = contentInset
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    func loadToolDefaults(from defaults: UserDefaults) {
        let preferences = ScreenshotAnnotationPreferences.self
        func width(_ tool: ScreenshotAnnotationTool) -> CGFloat {
            CGFloat(preferences.defaultWidth(for: tool, in: defaults))
        }
        for tool in ScreenshotAnnotationTool.toolsWithDefaultAppearance {
            toolColors[tool] = preferences.defaultColor(for: tool, in: defaults)
        }
        arrowLineWidthPoints = width(.arrow)
        rectangleLineWidthPoints = width(.rectangle)
        discardLineWidthPoints = width(.discard)
        ellipseLineWidthPoints = width(.ellipse)
        brushLineWidthPoints = width(.brush)
        penLineWidthPoints = width(.pen)
        highlighterLineWidthPoints = width(.highlighter)
        textOutlineWidthPoints = width(.text)
        numberBorderWidthPoints = width(.number)
        if arrowLineWidthPoints == 0, preferences.remembers(in: defaults),
           let scale = defaults.object(forKey: preferences.arrowScaleKey) as? Double,
           scale.isFinite {
            arrowThicknessScale = min(4, max(0.2, CGFloat(scale)))
        } else {
            arrowThicknessScale = 1
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let mouseTrackingArea { removeTrackingArea(mouseTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        mouseTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isCropping {
            let handle = cropHandle(at: location)
            (handle?.resizeCursor ?? (handle == .move ? .openHand : .crosshair)).set()
            return
        }
        let hit = elementHit(at: location, copying: event.modifierFlags.contains(.option))
        if contentInset == 0, let selectionHandle = selectionDrag(at: location),
           !isSelectedArrowBoxGrip(hit, at: location) {
            if hoveredIndex != nil { hoveredIndex = nil; needsDisplay = true }
            (selectionHandle.resizeCursor ?? .openHand).set()
            return
        }
        if hit == nil, let hoveredIndex, annotations.indices.contains(hoveredIndex) {
            let item = annotations[hoveredIndex]
            let rect = bounds(of: item)
            let grips = elementHandleRect(for: item, around: rect)
            if grips != rect && viewRect(grips).contains(location) {
                // Keep the grips visible while crossing the space between
                // the small annotation and a grip that has been spread out.
                NSCursor.crosshair.set()
                return
            }
        }
        if hoveredIndex != hit?.index {
            hoveredIndex = hit?.index
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
        if let hit {
            (hit.handle == .body && event.modifierFlags.contains(.option)
                ? NSCursor.dragCopy : cursor(for: hit.handle)).set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        strokeGestureIndex = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if !isCropping, !isAdjustingSelection, dragStart == nil,
           adjustStroke(at: location, deltaY: event.scrollingDeltaY,
                        timestamp: event.timestamp) {
            return
        }
        super.scrollWheel(with: event)
    }

    /// A trackpad sends many small deltas for one gesture. Nearby events on
    /// the same mark share one undo snapshot; moving to another mark starts a
    /// new undo step. Filled marks deliberately do not accept line width.
    @discardableResult
    func adjustStroke(at location: CGPoint, deltaY: CGFloat,
                      timestamp: TimeInterval) -> Bool {
        guard abs(deltaY) > 0.001, let hit = elementHit(at: location),
              annotations.indices.contains(hit.index) else { return false }
        let item = annotations[hit.index]
        let factor = exp(max(-30, min(30, deltaY)) * 0.025)
        let minimum = strokePixelsPerPoint
        let maximum = 40 * strokePixelsPerPoint
        let changed: ScreenshotAnnotation
        let visualWidth: CGFloat
        switch item.shape {
        case .arrow(let start, let end, let style, let width):
            let scale = min(4, max(0.2, factor))
            changed = .sizedArrow(start, end, style: style, width: width, scale: scale)
            visualWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
                from: start, to: end, minimumWidth: width) * scale
        case .sizedArrow(let start, let end, let style, let width, let oldScale):
            let scale = min(4, max(0.2, oldScale * factor))
            changed = .sizedArrow(start, end, style: style, width: width, scale: scale)
            visualWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
                from: start, to: end, minimumWidth: width) * scale
        case .bezierArrow(let start, let control, let end, let width):
            let scale = min(4, max(0.2, factor))
            changed = .sizedBezierArrow(start: start, control: control, end: end,
                                        width: width, scale: scale)
            visualWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
                from: start, to: end, minimumWidth: width) * scale
        case .sizedBezierArrow(let start, let control, let end, let width, let oldScale):
            let scale = min(4, max(0.2, oldScale * factor))
            changed = .sizedBezierArrow(start: start, control: control, end: end,
                                        width: width, scale: scale)
            visualWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
                from: start, to: end, minimumWidth: width) * scale
        case .arrowBox(var box):
            guard let point = imagePoint(location), !box.rect.contains(point) else { return false }
            box.arrowScale = min(4, max(0.2, box.arrowScale * factor))
            changed = .arrowBox(box)
            let arrow = box.connection
            visualWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
                from: arrow.tail, to: arrow.tip, minimumWidth: box.arrowWidth) * box.arrowScale
        case .rectangle(let rect):
            let width = min(maximum, max(minimum, legacyShapeLineWidth * factor))
            changed = .styledRectangle(rect, style: .squareOutline, width: width)
            visualWidth = width
        case .styledRectangle(let rect, let style, let oldWidth) where !style.isFilled:
            let width = min(maximum, max(minimum, oldWidth * factor))
            changed = .styledRectangle(rect, style: style, width: width)
            visualWidth = width
        case .styledRectangleWithRadius(let rect, let style, let oldWidth, let radius)
            where !style.isFilled:
            let width = min(maximum, max(minimum, oldWidth * factor))
            changed = .styledRectangleWithRadius(rect, style: style,
                                                  width: width, radius: radius)
            visualWidth = width
        case .ellipse(let rect):
            let width = min(maximum, max(minimum, legacyShapeLineWidth * factor))
            changed = .styledEllipse(rect, style: .outline, width: width)
            visualWidth = width
        case .styledEllipse(let rect, let style, let oldWidth) where !style.isFilled:
            let width = min(maximum, max(minimum, oldWidth * factor))
            changed = .styledEllipse(rect, style: style, width: width)
            visualWidth = width
        case .pen(let nodes, let oldWidth, let closed):
            let width = min(maximum, max(minimum, oldWidth * factor))
            changed = .pen(nodes, width: width, closed: closed)
            visualWidth = width
        case .brush(let points, let oldWidth):
            let width = min(maximum, max(minimum, oldWidth * factor))
            changed = .brush(points, width)
            visualWidth = width
        default: return false
        }
        if strokeGestureIndex != hit.index || timestamp - strokeGestureTime > 0.45 {
            pushUndo()
        }
        strokeGestureIndex = hit.index
        strokeGestureTime = timestamp
        annotations[hit.index] = changed.colored(item.color)
        selectedIndex = hit.index
        hoveredIndex = hit.index
        switch changed {
        case .sizedArrow(_, _, _, _, let scale),
             .sizedBezierArrow(_, _, _, _, let scale):
            rememberArrowAdjustment(scale: scale, width: visualWidth)
        case .arrowBox(let box):
            rememberArrowAdjustment(scale: box.arrowScale, width: visualWidth)
        case .styledRectangle(_, .discard, let width),
             .styledRectangleWithRadius(_, .discard, let width, _):
            discardLineWidthPoints = width / strokePixelsPerPoint
            onStrokePreferenceChanged?(.discard, discardLineWidthPoints)
        case .styledRectangle(_, _, let width),
             .styledRectangleWithRadius(_, _, let width, _):
            rectangleLineWidthPoints = width / strokePixelsPerPoint
            onStrokePreferenceChanged?(.rectangle, rectangleLineWidthPoints)
        case .styledEllipse(_, _, let width):
            ellipseLineWidthPoints = width / strokePixelsPerPoint
            onStrokePreferenceChanged?(.ellipse, ellipseLineWidthPoints)
        case .pen(_, let width, _):
            penLineWidthPoints = width / strokePixelsPerPoint
            onStrokePreferenceChanged?(.pen, penLineWidthPoints)
        case .brush(_, let width):
            brushLineWidthPoints = width / strokePixelsPerPoint
            onStrokePreferenceChanged?(.brush, brushLineWidthPoints)
        default: break
        }
        showStrokeHint("线宽 \(Int((visualWidth / strokePixelsPerPoint).rounded())) 点", near: location)
        onChange?()
        needsDisplay = true
        return true
    }

    private func rememberArrowAdjustment(scale: CGFloat, width: CGFloat) {
        if arrowLineWidthPoints > 0 {
            arrowLineWidthPoints = max(0.1, width / strokePixelsPerPoint)
        } else {
            arrowThicknessScale = scale
            onStrokePreferenceChanged?(.arrow, scale)
        }
    }

    private func showStrokeHint(_ message: String, near point: CGPoint) {
        strokeHintTask?.cancel()
        let label = strokeHint ?? StrokeHintField(labelWithString: "")
        label.stringValue = message
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.95).cgColor
        label.layer?.cornerRadius = 6
        label.frame = CGRect(x: min(bounds.maxX - 94, point.x + 18),
                             y: min(bounds.maxY - 28, point.y + 12),
                             width: 90, height: 24)
        if strokeHint == nil { addSubview(label); strokeHint = label }
        let task = DispatchWorkItem { [weak self, weak label] in
            guard let self, self.strokeHint === label else { return }
            label?.removeFromSuperview()
            self.strokeHint = nil
        }
        strokeHintTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: task)
    }

    private func cursor(for handle: ElementHandle) -> NSCursor {
        let position: ScreenshotResizeCursor
        switch handle {
        case .body, .pathAnchor, .pathIncoming, .pathOutgoing: return .openHand
        case .start, .topLeft: position = .topLeft
        case .control, .top: position = .top
        case .end, .bottomRight: position = .bottomRight
        case .magnification: return .resizeUpDown
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return position.cursor
    }
    override func layout() {
        super.layout()
        scanOverlay?.frame = imageRect
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var hasChanges: Bool {
        hasImageEdits || !annotations.isEmpty || activeTextField != nil || penNodes.count > 1
    }
    var canUndo: Bool { !undoStack.isEmpty || !penNodes.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty || !penRedoNodes.isEmpty }
    var isEditingText: Bool { activeTextField != nil }
    var isBuildingPenPath: Bool { !penNodes.isEmpty }

    func beginCrop() {
        commitText()
        finishPen()
        cancelDraft()
        pendingSticker = nil
        deselectElement()
        isCropping = true
        cropRect = CGRect(origin: .zero, size: imageSize)
        cropHasSelection = false
        cropStartPoint = nil
        needsDisplay = true
        onCropChanged?()
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        cropRect = nil
        cropStartPoint = nil
        cropDragHandle = nil
        needsDisplay = true
        onCropChanged?()
    }

    @discardableResult func applyCrop() -> Bool {
        guard isCropping, let cropRect,
              let rect = ScreenshotCropGeometry.pixelRect(cropRect, in: imageSize) else { return false }
        if rect == CGRect(origin: .zero, size: imageSize) { cancelCrop(); return true }
        let pixels = CGRect(x: rect.minX, y: imageSize.height - rect.maxY,
                            width: rect.width, height: rect.height)
        guard let cropped = image.cropping(to: pixels) else { return false }
        let previous = CGRect(origin: .zero, size: imageSize)
        pushUndo()
        cancelCrop()
        // Keep editable marks in pixel coordinates, including top-origin OCR lines.
        // Older snapshots retain both their base image and their original marks.
        replaceImage(cropped, from: previous, to: rect, preservingUndoHistory: true)
        hasImageEdits = true
        onImageSizeChanged?()
        onChange?()
        return true
    }

    private func cropHandle(at location: CGPoint) -> SelectionDrag? {
        guard let cropRect else { return nil }
        let rect = viewRect(cropRect)
        if let handle = handles(in: rect).first(where: {
            max(abs(location.x - $0.1.x), abs(location.y - $0.1.y)) <= 10
        })?.0 { return handle }
        return cropHasSelection && rect.contains(location) ? .move : nil
    }

    private func beginCropDrag(at location: CGPoint) {
        guard imageRect.insetBy(dx: -10, dy: -10).contains(location),
              let point = imagePoint(location) else { return }
        cropStartPoint = point
        cropStartRect = cropRect ?? CGRect(origin: .zero, size: imageSize)
        cropDragHandle = cropHandle(at: location)
    }

    private func updateCropDrag(at location: CGPoint) {
        guard let start = cropStartPoint, let point = imagePoint(location) else { return }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        let rect: CGRect
        if let handle = cropDragHandle {
            if handle == .move {
                rect = CGRect(x: min(imageSize.width - cropStartRect.width,
                                     max(0, cropStartRect.minX + delta.x)),
                              y: min(imageSize.height - cropStartRect.height,
                                     max(0, cropStartRect.minY + delta.y)),
                              width: cropStartRect.width, height: cropStartRect.height)
            } else {
                var left = cropStartRect.minX, right = cropStartRect.maxX
                var bottom = cropStartRect.minY, top = cropStartRect.maxY
                if handle.adjustsLeft { left = min(right - 1, max(0, left + delta.x)) }
                if handle.adjustsRight { right = max(left + 1, min(imageSize.width, right + delta.x)) }
                if handle.adjustsBottom { bottom = min(top - 1, max(0, bottom + delta.y)) }
                if handle.adjustsTop { top = max(bottom + 1, min(imageSize.height, top + delta.y)) }
                rect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
            }
        } else {
            rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        }
        cropRect = rect
        needsDisplay = true
        onCropChanged?()
    }

    private func finishCropDrag(at location: CGPoint) {
        guard cropStartPoint != nil else { return }
        updateCropDrag(at: location)
        if let cropRect, cropRect.width >= 1, cropRect.height >= 1 { cropHasSelection = true }
        else { cropRect = cropStartRect }
        cropStartPoint = nil
        cropDragHandle = nil
        needsDisplay = true
        onCropChanged?()
    }

    private var nextNumber: Int {
        (annotations.compactMap { item -> Int? in
            if case .number(_, let number, _, _) = item.shape { return number }
            return nil
        }.max() ?? 0) + 1
    }
    var hasTranslation: Bool {
        annotations.contains { if case .translation = $0 { return true }; return false }
    }

    func toggleTranslation(_ lines: [ScreenshotTranslatedLine]) {
        pushUndo()
        if let index = annotations.lastIndex(where: {
            if case .translation = $0 { return true }; return false
        }) {
            annotations.remove(at: index)
        } else {
            annotations.append(.translation(lines))
        }
        onChange?()
        needsDisplay = true
    }

    func loadDocument(_ data: Data) -> Bool {
        guard let document = try? JSONDecoder().decode(ScreenshotAnnotationDocument.self, from: data),
              ScreenshotAnnotationDocument.supportedVersions.contains(document.version),
              document.imageWidth == image.width,
              document.imageHeight == image.height else { return false }
        annotations = document.annotations
        undoStack.removeAll()
        redoStack.removeAll()
        selectedIndex = nil
        hoveredIndex = nil
        needsDisplay = true
        return true
    }

    func editPayload(maximumBytes: Int) throws -> ScreenshotEditPayload? {
        commitText()
        finishPen()
        guard !annotations.isEmpty else { return nil }
        let base = try MacScreenshotCapture.encode(image, maximumBytes: maximumBytes)
        let hasNewLayout = annotations.contains {
            if case .ellipticalMagnifier = $0.shape { return true }
            if case .translation(let lines) = $0.shape { return lines.contains { $0.fontSize != nil } }
            return false
        }
        let version: Int
        if annotations.contains(where: { if case .arrowBox = $0.shape { return true }; return false }) {
            version = 10
        } else if annotations.contains(where: { if case .rectangularMagnifier = $0.shape { return true }; return false }) {
            version = 9
        } else if annotations.contains(where: {
            switch $0.shape { case .pen, .sticker: return true; default: return false }
        }) {
            version = 8
        } else { version = hasNewLayout ? 7 : 6 }
        let document = ScreenshotAnnotationDocument(version: version,
            imageWidth: image.width, imageHeight: image.height, annotations: annotations)
        return ScreenshotEditPayload(baseImageData: base.data,
                                     annotationData: try JSONEncoder().encode(document))
    }

    private var imageSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    private var arrowWidth: CGFloat {
        max(3, 3 * imageSize.width / max(1, imageRect.width))
    }

    private func arrowScale(from start: CGPoint, to end: CGPoint) -> CGFloat {
        guard arrowLineWidthPoints > 0 else { return arrowThicknessScale }
        let automatic = ScreenshotArrowGeometry.effectiveShaftWidth(
            from: start, to: end, minimumWidth: arrowWidth)
        guard automatic > 0 else { return 1 }
        return min(4, max(0.2, arrowLineWidthPoints * strokePixelsPerPoint / automatic))
    }

    private func arrowAnnotation(from start: CGPoint, to end: CGPoint) -> ScreenshotAnnotation? {
        let length = hypot(end.x - start.x, end.y - start.y)
        switch arrowStyle {
        case .withRectangle:
            guard length >= max(12, 14 * pointsToImage) else { return nil }
            let canvas = CGRect(origin: .zero, size: imageSize)
            let margin = min(2 * pointsToImage, min(canvas.width, canvas.height) / 4)
            let area = canvas.insetBy(dx: margin, dy: margin)
            let size = CGSize(width: 108 * pointsToImage, height: 60 * pointsToImage)
            let rect = ScreenshotArrowBox.targetRect(from: start, to: end, size: size, in: area)
            var box = ScreenshotArrowBox(tail: start, rect: rect,
                arrowWidth: arrowWidth, arrowScale: 1,
                rectangleWidth: rectangleLineWidthPoints * strokePixelsPerPoint,
                rectangleRadius: rectangleCornerRadiusPoints * strokePixelsPerPoint)
            let arrow = box.connection
            box.arrowScale = arrowScale(from: arrow.tail, to: arrow.tip)
            return .arrowBox(box)
        case .bezier:
            let control = defaultBezierControl(from: start, to: end)
            let scale = arrowScale(from: start, to: end)
            return scale == 1
                ? .bezierArrow(start: start, control: control, end: end, width: arrowWidth)
                : .sizedBezierArrow(start: start, control: control, end: end, width: arrowWidth, scale: scale)
        case .rounded, .sharp:
            let scale = arrowScale(from: start, to: end)
            return scale == 1
                ? .arrow(start, end, style: arrowStyle, width: arrowWidth)
                : .sizedArrow(start, end, style: arrowStyle, width: arrowWidth, scale: scale)
        }
    }

    private var legacyShapeLineWidth: CGFloat {
        max(4, min(imageSize.width, imageSize.height) * 0.004)
    }

    private func boxAnnotation(in rect: CGRect) -> ScreenshotAnnotation {
        let isDiscard = tool == .discard
        let lineWidth = isDiscard ? discardLineWidthPoints : rectangleLineWidthPoints
        return .styledRectangleWithRadius(rect, style: isDiscard ? .discard : rectangleStyle,
            width: lineWidth * strokePixelsPerPoint, radius: rectangleCornerRadiusPoints * strokePixelsPerPoint)
    }

    private var ellipseLineWidth: CGFloat {
        ellipseLineWidthPoints * strokePixelsPerPoint
    }

    var pointsToImage: CGFloat {
        imageSize.width / max(1, imageRect.width)
    }

    private var imageRect: CGRect {
        // In the inline screenshot editor the view's bounds *are* the selected
        // screen rectangle. During a one-sided resize the old image retains
        // its previous aspect ratio until recapture finishes; aspect-fitting
        // that image would draw a second, proportionally sized blue frame
        // inside the eight handles instead of outlining the actual selection.
        if contentInset == 0 { return bounds }
        let available = bounds.insetBy(dx: contentInset, dy: contentInset)
        let size = fittedImageSize(in: available.size)
        return CGRect(x: available.midX - size.width / 2,
                      y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func fittedImageSize(in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    func fitEditor(to viewport: CGSize) {
        let padding = contentInset * 2
        let size = fittedImageSize(in: CGSize(width: viewport.width - padding,
                                              height: viewport.height - padding))
        let frameSize = CGSize(width: size.width + padding, height: size.height + padding)
        guard frame.size != frameSize else { return }
        setFrameSize(frameSize)
        updateTextEditor()
        needsDisplay = true
    }

    private func imagePoint(_ viewPoint: CGPoint, requireInside: Bool = false) -> CGPoint? {
        let rect = imageRect
        guard !rect.isEmpty, !requireInside || rect.contains(viewPoint) else { return nil }
        return CGPoint(
            x: min(imageSize.width, max(0, (viewPoint.x - rect.minX) * imageSize.width / rect.width)),
            y: min(imageSize.height, max(0, (viewPoint.y - rect.minY) * imageSize.height / rect.height))
        )
    }

    private func viewPoint(_ imagePoint: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.minX + imagePoint.x * rect.width / imageSize.width,
                       y: rect.minY + imagePoint.y * rect.height / imageSize.height)
    }

    private func defaultBezierControl(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let point = ScreenshotBezierArrowGeometry.defaultControl(from: start, to: end)
        return CGPoint(x: min(imageSize.width, max(0, point.x)),
                       y: min(imageSize.height, max(0, point.y)))
    }

    private var activeBezier: (start: CGPoint, control: CGPoint, end: CGPoint, width: CGFloat)? {
        guard let activeBezierIndex, annotations.indices.contains(activeBezierIndex) else { return nil }
        switch annotations[activeBezierIndex].shape {
        case .bezierArrow(let start, let control, let end, let width),
             .sizedBezierArrow(let start, let control, let end, let width, _):
            return (start, control, end, width)
        default: return nil
        }
    }

    private func bezierHandle(at location: CGPoint) -> (Int, BezierHandle)? {
        for index in annotations.indices.reversed() {
            let start: CGPoint
            let control: CGPoint
            let end: CGPoint
            switch annotations[index].shape {
            case .bezierArrow(let a, let b, let c, _),
                 .sizedBezierArrow(let a, let b, let c, _, _):
                start = a; control = b; end = c
            default: continue
            }
            for (handle, point) in [(BezierHandle.control, control),
                                    (.start, start), (.end, end)] {
                let center = viewPoint(point)
                if hypot(center.x - location.x, center.y - location.y) <= 16 {
                    return (index, handle)
                }
            }
        }
        return nil
    }

    var bezierControlCursorRects: [(CGRect, NSCursor)] {
        guard let activeBezier, let superview else { return [] }
        return [activeBezier.start, activeBezier.control, activeBezier.end].map { point in
            let center = convert(viewPoint(point), to: superview)
            return (CGRect(x: center.x - 16, y: center.y - 16,
                           width: 32, height: 32), NSCursor.openHand)
        }
    }

    private func translatedRect(_ line: ScreenshotTranslatedLine) -> CGRect {
        CGRect(x: line.sourceRect.minX,
               y: imageSize.height - line.sourceRect.maxY,
               width: line.sourceRect.width, height: line.sourceRect.height)
    }

    private func textBounds(at point: CGPoint, text: String, size: CGFloat) -> CGRect {
        ScreenshotTextRendering.bounds(at: point, text: text, size: size,
                                        fontOverride: ScreenshotTextRendering.legacyFont(size: size))
    }

    private func bounds(of item: ScreenshotAnnotation) -> CGRect {
        switch item {
        case .pen(let nodes, let width, let closed):
            return ScreenshotPenGeometry.path(nodes, closed: closed).boundingBoxOfPath
                .insetBy(dx: -width / 2, dy: -width / 2)
        case .sticker(let rect, _): return rect.standardized
        case .arrowBox(let box):
            return box.rect.insetBy(dx: -box.rectangleWidth / 2, dy: -box.rectangleWidth / 2)
                .union(box.arrowPath.boundingBoxOfPath)
        case .arrow(let start, let end, _, let width),
             .sizedArrow(let start, let end, _, let width, _):
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
                .insetBy(dx: -max(8, width * 4), dy: -max(8, width * 4))
        case .bezierArrow(let start, let control, let end, let width),
             .sizedBezierArrow(let start, let control, let end, let width, _):
            let xs = [start.x, control.x, end.x]
            let ys = [start.y, control.y, end.y]
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0))
                .insetBy(dx: -max(8, width * 4), dy: -max(8, width * 4))
        case .text(let point, let text, let size):
            return textBounds(at: point, text: text, size: size)
        case .styledText(let point, let text, let size, let style, _):
            let rect = ScreenshotTextRendering.bounds(at: point, text: text, size: size)
            return style.background(for: style.foreground) == nil ? rect
                : ScreenshotTextRendering.backgroundRect(rect, size: size)
        case .mosaic(let rect), .obscure(let rect, _, _), .spotlight(let rect), .rectangle(let rect),
             .filledRectangle(let rect), .ellipse(let rect),
             .styledRectangle(let rect, _, _),
             .styledRectangleWithRadius(let rect, _, _, _),
             .styledEllipse(let rect, _, _):
            return rect.standardized
        case .number(let point, _, let radius, _), .magnifier(let point, let radius):
            return CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        case .ellipticalMagnifier(let rect, _), .rectangularMagnifier(let rect, _):
            return rect.standardized
        case .highlighter(let points, let width, _), .brush(let points, let width):
            guard let first = points.first else { return .zero }
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return CGRect(x: xs.min() ?? first.x, y: ys.min() ?? first.y,
                          width: (xs.max() ?? first.x) - (xs.min() ?? first.x),
                          height: (ys.max() ?? first.y) - (ys.min() ?? first.y))
                .insetBy(dx: -width / 2, dy: -width / 2)
        case .translation(let lines):
            return lines.map(translatedRect).reduce(CGRect.null) { $0.union($1) }
        case .colored(let shape, _): return bounds(of: shape)
        }
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        let a = viewPoint(rect.origin)
        let b = viewPoint(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).standardized
    }

    private func elementHandleRect(for item: ScreenshotAnnotation, around rect: CGRect) -> CGRect {
        switch item.shape {
        case .pen, .arrow, .sizedArrow, .bezierArrow, .sizedBezierArrow, .number:
            return rect
        default: break
        }
        guard !rect.isNull, !rect.isEmpty else { return rect }
        // Spread cramped grips in view points. Resizing still applies the
        // pointer delta to the original image geometry, so it never jumps.
        let minimumSide = 44 * pointsToImage
        let width = max(rect.width, min(imageSize.width, minimumSide))
        let height = max(rect.height, min(imageSize.height, minimumSide))
        let x = width == rect.width ? rect.minX
            : min(max(0, rect.midX - width / 2), imageSize.width - width)
        let y = height == rect.height ? rect.minY
            : min(max(0, rect.midY - height / 2), imageSize.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func handles(for item: ScreenshotAnnotation) -> [(ElementHandle, CGPoint)] {
        switch item.shape {
        case .pen(let nodes, _, _):
            return nodes.enumerated().flatMap { index, node -> [(ElementHandle, CGPoint)] in
                var result: [(ElementHandle, CGPoint)] = [(.pathAnchor(index), node.point)]
                if let incoming = node.incoming { result.append((.pathIncoming(index), incoming)) }
                if let outgoing = node.outgoing { result.append((.pathOutgoing(index), outgoing)) }
                return result
            }
        case .arrow(let start, let end, _, _),
             .sizedArrow(let start, let end, _, _, _):
            return [(.start, start), (.end, end)]
        case .arrowBox(let box):
            let frame = elementHandleRect(for: item, around: box.rect)
            return [(.start, box.connection.tail),
                    (.topLeft, CGPoint(x: frame.minX, y: frame.maxY)),
                    (.topRight, CGPoint(x: frame.maxX, y: frame.maxY)),
                    (.bottomLeft, CGPoint(x: frame.minX, y: frame.minY)),
                    (.bottomRight, CGPoint(x: frame.maxX, y: frame.minY))]
        case .bezierArrow(let start, let control, let end, _),
             .sizedBezierArrow(let start, let control, let end, _, _):
            return [(.start, start), (.control, control), (.end, end)]
        case .number(let center, _, let radius, _):
            return [(.right, CGPoint(x: center.x + radius, y: center.y))]
        default:
            let rect = elementHandleRect(for: item, around: bounds(of: item))
            guard !rect.isNull, !rect.isEmpty else { return [] }
            var result: [(ElementHandle, CGPoint)] = [
                (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.top, CGPoint(x: rect.midX, y: rect.maxY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
                (.right, CGPoint(x: rect.maxX, y: rect.midY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottom, CGPoint(x: rect.midX, y: rect.minY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.left, CGPoint(x: rect.minX, y: rect.midY))
            ]
            if item.magnifierGeometry != nil {
                let gap = 28 * pointsToImage
                let marginX = min(24 * pointsToImage, imageSize.width / 4)
                let marginY = min(24 * pointsToImage, imageSize.height / 4)
                let x: CGFloat
                if rect.maxX + gap <= imageSize.width - marginX { x = rect.maxX + gap }
                else if rect.minX - gap >= marginX { x = rect.minX - gap }
                else { x = min(imageSize.width - marginX, max(marginX, rect.maxX - gap)) }
                let y = min(imageSize.height - marginY, max(marginY, rect.midY))
                result.insert((.magnification, CGPoint(x: x, y: y)), at: 0)
            }
            return result
        }
    }

    private func distance(_ point: CGPoint, toSegment start: CGPoint,
                          _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy)
                           / lengthSquared))
        return hypot(point.x - start.x - t * dx,
                     point.y - start.y - t * dy)
    }

    private func bodyHit(_ item: ScreenshotAnnotation, at point: CGPoint,
                         tolerance: CGFloat) -> Int? {
        switch item {
        case .pen(let nodes, let width, let closed):
            return ScreenshotPenGeometry.path(nodes, closed: closed).copy(
                strokingWithWidth: max(width, tolerance * 2), lineCap: .round,
                lineJoin: .round, miterLimit: 2).contains(point) ? 0 : nil
        case .sticker(let rect, _): return rect.contains(point) ? 0 : nil
        case .colored(let shape, _): return bodyHit(shape, at: point, tolerance: tolerance)
        case .arrowBox(let box):
            if ScreenshotRectangleStyle.roundedOutline.contains(point, in: box.rect, radius: box.radius,
                width: box.rectangleWidth, tolerance: tolerance) { return 0 }
            let path = box.arrowPath
            return path.contains(point) || path.copy(strokingWithWidth: tolerance * 2,
                lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point) ? 0 : nil
        case .arrow(let start, let end, let style, let width):
            let path = ScreenshotArrowGeometry.path(from: start, to: end,
                                                     style: style, shaftWidth: width)
            return path.contains(point) || distance(point, toSegment: start, end) <= tolerance
                ? 0 : nil
        case .sizedArrow(let start, let end, let style, let width, let scale):
            let path = ScreenshotArrowGeometry.path(from: start, to: end,
                style: style, shaftWidth: width, thicknessScale: scale)
            return path.contains(point) || path.copy(strokingWithWidth: tolerance * 2,
                lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point) ? 0 : nil
        case .bezierArrow(let start, let control, let end, let width):
            let path = ScreenshotBezierArrowGeometry.path(from: start, control: control,
                    to: end, minimumWidth: width)
            let ring = ScreenshotBezierArrowGeometry.tailRing(from: start, to: end,
                    minimumWidth: width)
            return path.contains(point) || path.copy(strokingWithWidth: tolerance * 2,
                lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point)
                || hypot(point.x - start.x, point.y - start.y) <= ring.rect.width / 2 + tolerance
                ? 0 : nil
        case .sizedBezierArrow(let start, let control, let end, let width, let scale):
            let path = ScreenshotBezierArrowGeometry.path(from: start, control: control,
                to: end, minimumWidth: width, thicknessScale: scale)
            let ring = ScreenshotBezierArrowGeometry.tailRing(from: start, to: end,
                minimumWidth: width, thicknessScale: scale)
            return path.contains(point) || path.copy(strokingWithWidth: tolerance * 2,
                lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point)
                || hypot(point.x - start.x, point.y - start.y) <= ring.rect.width / 2 + tolerance
                ? 0 : nil
        case .rectangle(let rect), .spotlight(let rect):
            let outside = rect.standardized.insetBy(dx: -tolerance, dy: -tolerance)
            let inside = rect.standardized.insetBy(dx: tolerance, dy: tolerance)
            return outside.contains(point) && (inside.isEmpty || !inside.contains(point)) ? 0 : nil
        case .ellipse(let rect):
            let rect = rect.standardized
            guard rect.width > 0, rect.height > 0 else { return nil }
            let radiusX = rect.width / 2
            let radiusY = rect.height / 2
            let radial = hypot((point.x - rect.midX) / radiusX,
                               (point.y - rect.midY) / radiusY)
            return abs(radial - 1) * min(radiusX, radiusY) <= tolerance ? 0 : nil
        case .styledRectangle(let rect, let style, let width):
            let rect = rect.standardized
            let radius = style.isRounded ? min(max(6, min(imageSize.width, imageSize.height) * 0.04),
                                               rect.width * 0.22, rect.height * 0.22) : 0
            return style.contains(point, in: rect, radius: radius, width: width, tolerance: tolerance) ? 0 : nil
        case .styledRectangleWithRadius(let rect, let style, let width, let savedRadius):
            return style.contains(point, in: rect.standardized, radius: savedRadius,
                                  width: width, tolerance: tolerance) ? 0 : nil
        case .styledEllipse(let rect, let style, let width):
            let path = CGPath(ellipseIn: rect.standardized, transform: nil)
            if style.isFilled { return path.contains(point) ? 0 : nil }
            return path.copy(strokingWithWidth: max(width, tolerance * 2),
                lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point) ? 0 : nil
        case .filledRectangle(let rect), .mosaic(let rect), .obscure(let rect, _, _):
            return rect.standardized.contains(point) ? 0 : nil
        case .magnifier(let center, let radius):
            return hypot(point.x - center.x, point.y - center.y) <= radius + tolerance ? 0 : nil
        case .ellipticalMagnifier(let rect, _):
            return CGPath(ellipseIn: rect.insetBy(dx: -tolerance, dy: -tolerance),
                          transform: nil).contains(point) ? 0 : nil
        case .rectangularMagnifier(let rect, _):
            return ScreenshotMagnifierStyle.roundedRectangle.path(
                in: rect.insetBy(dx: -tolerance, dy: -tolerance)
            ).contains(point) ? 0 : nil
        case .text, .styledText, .number:
            return bounds(of: item).insetBy(dx: -tolerance, dy: -tolerance).contains(point) ? 0 : nil
        case .highlighter(let points, let width, _), .brush(let points, let width):
            guard let first = points.first else { return nil }
            if points.count == 1 {
                return hypot(point.x - first.x, point.y - first.y) <= width / 2 + tolerance
                    ? 0 : nil
            }
            for pair in zip(points, points.dropFirst()) {
                if distance(point, toSegment: pair.0, pair.1) <= width / 2 + tolerance {
                    return 0
                }
            }
            return nil
        case .translation(let lines):
            return lines.firstIndex { translatedRect($0).insetBy(
                dx: -tolerance, dy: -tolerance).contains(point) }
        }
    }

    private func elementHit(at location: CGPoint, copying: Bool = false) -> ElementHit? {
        guard let point = imagePoint(location, requireInside: true) else { return nil }
        var nearestHandle: (hit: ElementHit, distance: CGFloat)?
        for index in [hoveredIndex ?? selectedIndex, activeBezierIndex].compactMap({ $0 })
        where annotations.indices.contains(index) {
            let item = annotations[index]
            let rect = bounds(of: item)
            let radius: CGFloat = elementHandleRect(for: item, around: rect) == rect ? 16 : 10
            for (handle, position) in handles(for: item) {
                let center = viewPoint(position)
                let distance = hypot(center.x - location.x, center.y - location.y)
                if distance <= radius, distance < (nearestHandle?.distance ?? .infinity) {
                    nearestHandle = (ElementHit(index: index, handle: handle, translationLine: nil), distance)
                }
            }
        }
        if let nearestHandle {
            // Option prefers an actual element body outside the visible grip,
            // while retaining the normal generous hit area outside the mark.
            // This matters for small numbered marks whose grip overlaps them.
            let item = annotations[nearestHandle.hit.index]
            if copying, nearestHandle.distance > 6, bounds(of: item).contains(point),
               let line = bodyHit(item, at: point, tolerance: 9 * pointsToImage) {
                return ElementHit(index: nearestHandle.hit.index, handle: .body, translationLine: line)
            }
            return nearestHandle.hit
        }
        let tolerance = 9 * imageSize.width / max(1, imageRect.width)
        var magnifierHit: ElementHit?
        for index in annotations.indices.reversed() {
            let item = annotations[index]
            guard let line = bodyHit(item, at: point, tolerance: tolerance) else { continue }
            let hit = ElementHit(index: index, handle: .body, translationLine: line)
            if item.magnifierGeometry != nil {
                if magnifierHit == nil { magnifierHit = hit }
            } else {
                return hit
            }
        }
        return magnifierHit
    }

    private func isSelectedArrowBoxGrip(_ hit: ElementHit?, at location: CGPoint) -> Bool {
        guard let hit, hit.index == selectedIndex, hit.handle != .body,
              case .arrowBox = annotations[hit.index].shape else { return false }
        return handles(for: annotations[hit.index]).contains { handle, point in
            let center = viewPoint(point)
            return handle == hit.handle && hypot(center.x - location.x, center.y - location.y) <= 8
        }
    }

    private func pushUndo(_ before: [ScreenshotAnnotation]? = nil) {
        strokeGestureIndex = nil
        undoStack.append(Snapshot(image: image, annotations: before ?? annotations, hasImageEdits: hasImageEdits))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func adjustedRect(_ rect: CGRect, handle: ElementHandle,
                              delta: CGPoint, minimum: CGFloat = 4) -> CGRect {
        let rect = rect.standardized
        var left = rect.minX
        var right = rect.maxX
        var bottom = rect.minY
        var top = rect.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: left = min(right - minimum, left + delta.x)
        case .topRight, .right, .bottomRight: right = max(left + minimum, right + delta.x)
        default: break
        }
        switch handle {
        case .topLeft, .top, .topRight: top = max(bottom + minimum, top + delta.y)
        case .bottomLeft, .bottom, .bottomRight: bottom = min(top - minimum, bottom + delta.y)
        default: break
        }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    private func fitArrowBoxEdit(from original: ScreenshotArrowBox,
                                 to requested: ScreenshotArrowBox) -> ScreenshotArrowBox {
        let area = CGRect(origin: .zero, size: imageSize)
        func hasRoom(_ box: ScreenshotArrowBox) -> Bool {
            let arrow = box.connection
            return area.contains(arrow.tail) && area.contains(arrow.tip)
        }

        var result = requested
        if !hasRoom(requested), hasRoom(original) {
            // Stop at the last visible position if the resize would push the arrow outside the screenshot.
            result = original
            let startTail = original.connection.tail
            var lower: CGFloat = 0
            var upper: CGFloat = 1
            for _ in 0..<12 {
                let fraction = (lower + upper) / 2
                func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
                    start + (end - start) * fraction
                }
                var candidate = original
                candidate.tail = CGPoint(x: interpolate(startTail.x, requested.tail.x),
                                         y: interpolate(startTail.y, requested.tail.y))
                candidate.rect = CGRect(x: interpolate(original.rect.minX, requested.rect.minX),
                                        y: interpolate(original.rect.minY, requested.rect.minY),
                                        width: interpolate(original.rect.width, requested.rect.width),
                                        height: interpolate(original.rect.height, requested.rect.height))
                if hasRoom(candidate) { lower = fraction; result = candidate }
                else { upper = fraction }
            }
        }
        result.tail = result.connection.tail
        return result
    }

    private func changed(_ item: ScreenshotAnnotation, handle: ElementHandle,
                         delta: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> ScreenshotAnnotation {
        func moved(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.x, y: point.y + delta.y)
        }
        func shapeRect(_ rect: CGRect) -> CGRect {
            if handle == .body { return rect.offsetBy(dx: delta.x, dy: delta.y) }
            let next = adjustedRect(rect, handle: handle, delta: delta)
            guard modifiers.contains(.option) else { return next }
            let left = [.left, .topLeft, .bottomLeft].contains(handle)
            let right = [.right, .topRight, .bottomRight].contains(handle)
            let top = [.top, .topLeft, .topRight].contains(handle)
            let bottom = [.bottom, .bottomLeft, .bottomRight].contains(handle)
            let side = (left || right) && !(top || bottom) ? next.width
                : (!(left || right) ? next.height
                   : (abs(delta.x) >= abs(delta.y) ? next.width : next.height))
            return CGRect(x: left ? rect.maxX - side : (right ? rect.minX : rect.midX - side / 2),
                          y: bottom ? rect.maxY - side : (top ? rect.minY : rect.midY - side / 2),
                          width: side, height: side)
        }
        switch item {
        case .colored(let shape, let color):
            return changed(shape, handle: handle, delta: delta, modifiers: modifiers).colored(color)
        case .pen(var nodes, let width, let closed):
            switch handle {
            case .pathAnchor(let index) where nodes.indices.contains(index):
                nodes[index] = nodes[index].map(moved)
            case .pathIncoming(let index) where nodes.indices.contains(index):
                nodes[index].incoming = moved(nodes[index].incoming ?? nodes[index].point)
            case .pathOutgoing(let index) where nodes.indices.contains(index):
                nodes[index].outgoing = moved(nodes[index].outgoing ?? nodes[index].point)
            default: nodes = nodes.map { $0.map(moved) }
            }
            return .pen(nodes, width: width, closed: closed)
        case .sticker(let rect, let asset):
            if handle == .body { return .sticker(rect.offsetBy(dx: delta.x, dy: delta.y), asset) }
            let next = adjustedRect(rect, handle: handle, delta: delta)
            // Image assets retain their native aspect; Option allows free sizing.
            if modifiers.contains(.option) { return .sticker(next, asset) }
            let horizontal = [.left, .right].contains(handle)
            let vertical = [.top, .bottom].contains(handle)
            let ratio = CGFloat(asset.width) / CGFloat(max(1, asset.height))
            let width = vertical ? next.height * ratio : next.width
            let height = horizontal || !vertical ? width / ratio : next.height
            let x = [.left, .topLeft, .bottomLeft].contains(handle) ? rect.maxX - width
                : (vertical ? rect.midX - width / 2 : rect.minX)
            let y = [.bottom, .bottomLeft, .bottomRight].contains(handle) ? rect.maxY - height
                : (horizontal ? rect.midY - height / 2 : rect.minY)
            return .sticker(CGRect(x: x, y: y, width: width, height: height), asset)
        case .obscure(let rect, let mode, let strength):
            let area = handle == .body ? rect.offsetBy(dx: delta.x, dy: delta.y)
                : adjustedRect(rect, handle: handle, delta: delta)
            return .obscure(area, mode: mode, strength: strength)
        case .arrow(let start, let end, let style, let width):
            return .arrow(handle == .end ? start : moved(start),
                          handle == .start ? end : moved(end),
                          style: style, width: width)
        case .sizedArrow(let start, let end, let style, let width, let scale):
            return .sizedArrow(handle == .end ? start : moved(start),
                handle == .start ? end : moved(end), style: style, width: width, scale: scale)
        case .arrowBox(let original):
            var box = original
            if handle == .body {
                box.tail = moved(box.tail)
                box.rect = shapeRect(box.rect)
                return .arrowBox(box)
            }
            box.tail = original.connection.tail
            if handle == .start { box.tail = moved(box.tail) }
            else { box.rect = shapeRect(box.rect) }
            return .arrowBox(fitArrowBoxEdit(from: original, to: box))
        case .bezierArrow(let start, let control, let end, let width):
            return .bezierArrow(
                start: handle == .body || handle == .start ? moved(start) : start,
                control: handle == .body || handle == .control ? moved(control) : control,
                end: handle == .body || handle == .end ? moved(end) : end,
                width: width
            )
        case .sizedBezierArrow(let start, let control, let end, let width, let scale):
            return .sizedBezierArrow(
                start: handle == .body || handle == .start ? moved(start) : start,
                control: handle == .body || handle == .control ? moved(control) : control,
                end: handle == .body || handle == .end ? moved(end) : end,
                width: width, scale: scale
            )
        case .text(let point, let text, let size),
             .styledText(let point, let text, let size, _, _):
            func result(_ point: CGPoint, _ size: CGFloat) -> ScreenshotAnnotation {
                if case .styledText(_, _, _, let style, let outlineWidth) = item {
                    return .styledText(point, text, fontSize: size, style: style, outlineWidth: outlineWidth)
                }
                return .text(point, text, fontSize: size)
            }
            if handle == .body { return result(moved(point), size) }
            let old = bounds(of: item)
            let next = adjustedRect(old, handle: handle, delta: delta)
            let widthRatio = next.width / max(1, old.width)
            let heightRatio = next.height / max(1, old.height)
            let ratio: CGFloat
            switch handle {
            case .left, .right: ratio = widthRatio
            case .top, .bottom: ratio = heightRatio
            default: ratio = (widthRatio + heightRatio) / 2
            }
            let newSize = min(300, max(8, size * ratio))
            let oldDescent = point.y - old.minY
            return result(CGPoint(x: next.minX + (point.x - old.minX) * newSize / max(1, size),
                                  y: next.minY + oldDescent * newSize / max(1, size)), newSize)
        case .magnifier, .ellipticalMagnifier, .rectangularMagnifier:
            guard let lens = item.magnifierGeometry else { return item }
            if handle == .magnification {
                let factor = exp(delta.y / max(1, 70 * pointsToImage))
                let zoom = (min(8, max(1, lens.magnification * factor)) * 10).rounded() / 10
                return lens.style.annotation(in: lens.rect, magnification: zoom)
            }
            var rect = handle == .body ? lens.rect.offsetBy(dx: delta.x, dy: delta.y)
                : adjustedRect(lens.rect, handle: handle, delta: delta, minimum: 1)
            if handle != .body, modifiers.contains(.shift) {
                let side: CGFloat
                switch handle {
                case .left, .right: side = rect.width
                case .top, .bottom: side = rect.height
                default: side = max(rect.width, rect.height)
                }
                let x: CGFloat
                let y: CGFloat
                switch handle {
                case .left, .topLeft, .bottomLeft: x = lens.rect.maxX - side
                case .top, .bottom: x = lens.rect.midX - side / 2
                default: x = lens.rect.minX
                }
                switch handle {
                case .bottom, .bottomLeft, .bottomRight: y = lens.rect.maxY - side
                case .left, .right: y = lens.rect.midY - side / 2
                default: y = lens.rect.minY
                }
                rect = CGRect(x: x, y: y, width: side, height: side)
            }
            return lens.style.annotation(in: rect, magnification: lens.magnification)
        case .spotlight(let rect):
            return .spotlight(handle == .body ? rect.offsetBy(dx: delta.x, dy: delta.y)
                              : adjustedRect(rect, handle: handle, delta: delta))
        case .mosaic(let rect):
            return .mosaic(handle == .body ? rect.offsetBy(dx: delta.x, dy: delta.y)
                           : adjustedRect(rect, handle: handle, delta: delta))
        case .rectangle(let rect):
            return .rectangle(shapeRect(rect))
        case .filledRectangle(let rect):
            return .filledRectangle(shapeRect(rect))
        case .styledRectangle(let rect, let style, let width):
            return .styledRectangle(shapeRect(rect), style: style, width: width)
        case .styledRectangleWithRadius(let rect, let style, let width, let radius):
            return .styledRectangleWithRadius(
                shapeRect(rect),
                style: style, width: width, radius: radius)
        case .ellipse(let rect):
            return .ellipse(shapeRect(rect))
        case .styledEllipse(let rect, let style, let width):
            return .styledEllipse(shapeRect(rect), style: style, width: width)
        case .number(let center, let number, let radius, let borderWidth):
            if handle == .body { return .number(moved(center), number, radius, borderWidth: borderWidth) }
            return .number(center, number, min(200, max(6, radius + delta.x)), borderWidth: borderWidth)
        case .highlighter(let points, let width, let opacity):
            if handle == .body { return .highlighter(points.map(moved), width, opacity: opacity) }
            let old = bounds(of: item)
            let next = adjustedRect(old, handle: handle, delta: delta)
            let sx = next.width / max(1, old.width)
            let sy = next.height / max(1, old.height)
            return .highlighter(points.map { point in
                CGPoint(x: next.minX + (point.x - old.minX) * sx,
                        y: next.minY + (point.y - old.minY) * sy)
            }, max(2, width * min(sx, sy)), opacity: opacity)
        case .brush(let points, let width):
            if handle == .body { return .brush(points.map(moved), width) }
            let old = bounds(of: item)
            let next = adjustedRect(old, handle: handle, delta: delta)
            let sx = next.width / max(1, old.width)
            let sy = next.height / max(1, old.height)
            return .brush(points.map { point in
                CGPoint(x: next.minX + (point.x - old.minX) * sx,
                        y: next.minY + (point.y - old.minY) * sy)
            }, max(1, width * min(sx, sy)))
        case .translation(let lines):
            if handle == .body {
                return .translation(lines.map { line in
                    var next = line
                    next.sourceRect = next.sourceRect.offsetBy(dx: delta.x, dy: -delta.y)
                    return next
                })
            }
            let old = bounds(of: item)
            let next = adjustedRect(old, handle: handle, delta: delta)
            let sx = next.width / max(1, old.width)
            let sy = next.height / max(1, old.height)
            return .translation(lines.map { line in
                var line = line
                let rect = translatedRect(line)
                let transformed = CGRect(
                    x: next.minX + (rect.minX - old.minX) * sx,
                    y: next.minY + (rect.minY - old.minY) * sy,
                    width: max(4, rect.width * sx), height: max(4, rect.height * sy)
                )
                line.sourceRect = CGRect(x: transformed.minX,
                    y: imageSize.height - transformed.maxY,
                    width: transformed.width, height: transformed.height)
                line.fontSize = line.fontSize.map { $0 * min(sx, sy) }
                return line
            })
        }
    }

    func replaceImage(_ next: CGImage, from previousFrame: CGRect? = nil,
                      to nextFrame: CGRect? = nil, movingSelection: Bool = false,
                      preservingUndoHistory: Bool = false) {
        if let previousFrame, let nextFrame,
           previousFrame.width > 0, previousFrame.height > 0,
           nextFrame.width > 0, nextFrame.height > 0 {
            let oldScaleX = CGFloat(image.width) / previousFrame.width
            let oldScaleY = CGFloat(image.height) / previousFrame.height
            let newScaleX = CGFloat(next.width) / nextFrame.width
            let newScaleY = CGFloat(next.height) / nextFrame.height
            let offsetX = movingSelection ? 0 : previousFrame.minX - nextFrame.minX
            let offsetY = movingSelection ? 0 : previousFrame.minY - nextFrame.minY
            let sizeScale = (newScaleX / oldScaleX + newScaleY / oldScaleY) / 2
            let oldImageHeight = CGFloat(image.height)
            let newImageHeight = CGFloat(next.height)
            func point(_ old: CGPoint) -> CGPoint {
                CGPoint(x: (old.x / oldScaleX + offsetX) * newScaleX,
                        y: (old.y / oldScaleY + offsetY) * newScaleY)
            }
            func rect(_ old: CGRect) -> CGRect {
                let lower = point(old.origin)
                let upper = point(CGPoint(x: old.maxX, y: old.maxY))
                return CGRect(x: lower.x, y: lower.y,
                              width: upper.x - lower.x, height: upper.y - lower.y)
            }
            func annotation(_ item: ScreenshotAnnotation) -> ScreenshotAnnotation {
                switch item {
                case .arrow(let start, let end, let style, let width):
                    return .arrow(point(start), point(end), style: style,
                                  width: width * sizeScale)
                case .sizedArrow(let start, let end, let style, let width, let scale):
                    return .sizedArrow(point(start), point(end), style: style,
                                       width: width * sizeScale, scale: scale)
                case .bezierArrow(let start, let control, let end, let width):
                    return .bezierArrow(start: point(start), control: point(control),
                                        end: point(end), width: width * sizeScale)
                case .sizedBezierArrow(let start, let control, let end, let width, let scale):
                    return .sizedBezierArrow(start: point(start), control: point(control),
                                             end: point(end), width: width * sizeScale,
                                             scale: scale)
                case .arrowBox(var box):
                    box.tail = point(box.tail)
                    box.rect = rect(box.rect)
                    box.arrowWidth *= sizeScale
                    box.rectangleWidth *= sizeScale
                    box.rectangleRadius = box.rectangleRadius.map { $0 * sizeScale }
                    return .arrowBox(box)
                case .text(let origin, let text, let fontSize):
                    return .text(point(origin), text, fontSize: fontSize * sizeScale)
                case .styledText(let origin, let text, let fontSize, let style, let outlineWidth):
                    return .styledText(point(origin), text, fontSize: fontSize * sizeScale,
                                       style: style, outlineWidth: outlineWidth.map { $0 * sizeScale })
                case .colored(let shape, let color): return annotation(shape).colored(color)
                case .obscure(let area, let mode, let strength):
                    return .obscure(rect(area), mode: mode, strength: strength)
                case .mosaic(let area): return .mosaic(rect(area))
                case .spotlight(let area): return .spotlight(rect(area))
                case .magnifier(let center, let radius):
                    return .magnifier(center: point(center), radius: radius * sizeScale)
                case .ellipticalMagnifier(let area, let magnification):
                    return .ellipticalMagnifier(rect(area), magnification: magnification)
                case .rectangularMagnifier(let area, let magnification):
                    return .rectangularMagnifier(rect(area), magnification: magnification)
                case .rectangle(let area): return .rectangle(rect(area))
                case .filledRectangle(let area): return .filledRectangle(rect(area))
                case .styledRectangle(let area, let style, let width):
                    return .styledRectangle(rect(area), style: style,
                                            width: width * sizeScale)
                case .styledRectangleWithRadius(let area, let style, let width, let radius):
                    return .styledRectangleWithRadius(rect(area), style: style,
                        width: width * sizeScale, radius: radius * sizeScale)
                case .ellipse(let area): return .ellipse(rect(area))
                case .styledEllipse(let area, let style, let width):
                    return .styledEllipse(rect(area), style: style,
                                          width: width * sizeScale)
                case .number(let center, let number, let radius, let borderWidth):
                    return .number(point(center), number, radius * sizeScale,
                                   borderWidth: borderWidth.map { $0 * sizeScale })
                case .highlighter(let points, let width, let opacity):
                    return .highlighter(points.map(point), width * sizeScale, opacity: opacity)
                case .brush(let points, let width):
                    return .brush(points.map(point), width * sizeScale)
                case .pen(let nodes, let width, let closed):
                    return .pen(nodes.map { $0.map(point) }, width: width * sizeScale, closed: closed)
                case .sticker(let area, let asset): return .sticker(rect(area), asset)
                case .translation(let lines):
                    return .translation(lines.map { line in
                        var line = line
                        let bottomOrigin = CGRect(x: line.sourceRect.minX,
                            y: oldImageHeight - line.sourceRect.maxY,
                            width: line.sourceRect.width, height: line.sourceRect.height)
                        let mapped = rect(bottomOrigin)
                        line.sourceRect = CGRect(x: mapped.minX,
                            y: newImageHeight - mapped.maxY,
                            width: mapped.width, height: mapped.height)
                        line.fontSize = line.fontSize.map { $0 * sizeScale }
                        return line
                    })
                }
            }
            annotations = annotations.map(annotation)
            if !preservingUndoHistory {
                undoStack = undoStack.map {
                    Snapshot(image: next, annotations: $0.annotations.map(annotation), hasImageEdits: $0.hasImageEdits)
                }
                redoStack = redoStack.map {
                    Snapshot(image: next, annotations: $0.annotations.map(annotation), hasImageEdits: $0.hasImageEdits)
                }
                strokePixelsPerPoint = newScaleX
            }
        }
        image = next
        obscuredImages.removeAllObjects()
        isAdjustingSelection = false
        needsDisplay = true
    }

    private var selectionHandles: [(SelectionDrag, CGPoint)] {
        handles(in: bounds)
    }

    private func handles(in bounds: CGRect) -> [(SelectionDrag, CGPoint)] {
        let middleX = bounds.midX
        let middleY = bounds.midY
        return [
            (.topLeft, CGPoint(x: bounds.minX, y: bounds.maxY)),
            (.top, CGPoint(x: middleX, y: bounds.maxY)),
            (.topRight, CGPoint(x: bounds.maxX, y: bounds.maxY)),
            (.right, CGPoint(x: bounds.maxX, y: middleY)),
            (.bottomRight, CGPoint(x: bounds.maxX, y: bounds.minY)),
            (.bottom, CGPoint(x: middleX, y: bounds.minY)),
            (.bottomLeft, CGPoint(x: bounds.minX, y: bounds.minY)),
            (.left, CGPoint(x: bounds.minX, y: middleY))
        ]
    }

    var selectionResizeCursorRects: [(CGRect, NSCursor)] {
        guard contentInset == 0, let superview else { return [] }
        let border: CGFloat = 9
        let edgeRects = [
            CGRect(x: -border, y: -border, width: bounds.width + 2 * border, height: 2 * border),
            CGRect(x: -border, y: bounds.height - border,
                   width: bounds.width + 2 * border, height: 2 * border),
            CGRect(x: -border, y: border, width: 2 * border,
                   height: max(0, bounds.height - 2 * border)),
            CGRect(x: bounds.width - border, y: border, width: 2 * border,
                   height: max(0, bounds.height - 2 * border))
        ].map { (convert($0, to: superview), NSCursor.openHand) }
        let handles = selectionHandles.compactMap { handle, point -> (CGRect, NSCursor)? in
            guard let cursor = handle.resizeCursor else { return nil }
            let center = convert(point, to: superview)
            return (CGRect(x: center.x - Self.handleHitRadius,
                           y: center.y - Self.handleHitRadius,
                           width: Self.handleHitRadius * 2,
                           height: Self.handleHitRadius * 2), cursor)
        }
        return edgeRects + handles
    }

    private func selectionDrag(at point: CGPoint) -> SelectionDrag? {
        if let (handle, _) = selectionHandles.first(where: { item in
            let center = item.1
            return max(abs(point.x - center.x), abs(point.y - center.y)) <= Self.handleHitRadius
        }) {
            return handle
        }
        let border: CGFloat = 9
        let nearBorder = bounds.insetBy(dx: -border, dy: -border).contains(point)
            && !bounds.insetBy(dx: border, dy: border).contains(point)
        return nearBorder ? .move : nil
    }

    private func adjustedSelection(to point: CGPoint,
                                   modifiers: NSEvent.ModifierFlags = []) -> CGRect {
        guard let selectionDrag, let container = superview else { return frame }
        var delta = CGPoint(x: point.x - selectionStartPoint.x,
                            y: point.y - selectionStartPoint.y)
        if modifiers.contains(.shift), !modifiers.contains(.option) {
            if selectionConstraintHorizontal == nil, hypot(delta.x, delta.y) > 1 {
                selectionConstraintHorizontal = abs(delta.x) >= abs(delta.y)
            }
            if let horizontal = selectionConstraintHorizontal {
                if horizontal { delta.y = 0 } else { delta.x = 0 }
            }
        } else { selectionConstraintHorizontal = nil }
        let initial = selectionStartFrame
        if selectionDrag == .move {
            return CGRect(
                x: min(max(0, initial.minX + delta.x), container.bounds.maxX - initial.width),
                y: min(max(0, initial.minY + delta.y), container.bounds.maxY - initial.height),
                width: initial.width, height: initial.height
            ).integral
        }
        let minimumWidth = min(32, initial.width)
        let minimumHeight = min(32, initial.height)
        var left = initial.minX
        var right = initial.maxX
        var bottom = initial.minY
        var top = initial.maxY
        if selectionDrag.adjustsLeft {
            left = min(max(0, left + delta.x), right - minimumWidth)
        }
        if selectionDrag.adjustsRight {
            right = min(max(left + minimumWidth, right + delta.x), container.bounds.maxX)
        }
        if selectionDrag.adjustsBottom {
            bottom = min(max(0, bottom + delta.y), top - minimumHeight)
        }
        if selectionDrag.adjustsTop {
            top = min(max(bottom + minimumHeight, top + delta.y), container.bounds.maxY)
        }
        if modifiers.contains(.option) {
            let adjustsX = selectionDrag.adjustsLeft || selectionDrag.adjustsRight
            let adjustsY = selectionDrag.adjustsTop || selectionDrag.adjustsBottom
            let requested: CGFloat
            if !adjustsY { requested = right - left }
            else if !adjustsX { requested = top - bottom }
            else { requested = abs(delta.x) >= abs(delta.y) ? right - left : top - bottom }
            let anchorX = selectionDrag.adjustsLeft ? initial.maxX
                : (selectionDrag.adjustsRight ? initial.minX : initial.midX)
            let anchorY = selectionDrag.adjustsBottom ? initial.maxY
                : (selectionDrag.adjustsTop ? initial.minY : initial.midY)
            let availableX = selectionDrag.adjustsLeft ? anchorX
                : (selectionDrag.adjustsRight ? container.bounds.maxX - anchorX
                    : min(anchorX, container.bounds.maxX - anchorX) * 2)
            let availableY = selectionDrag.adjustsBottom ? anchorY
                : (selectionDrag.adjustsTop ? container.bounds.maxY - anchorY
                    : min(anchorY, container.bounds.maxY - anchorY) * 2)
            let side = max(1, min(requested, availableX, availableY))
            return CGRect(x: selectionDrag.adjustsLeft ? anchorX - side
                            : (selectionDrag.adjustsRight ? anchorX : anchorX - side / 2),
                          y: selectionDrag.adjustsBottom ? anchorY - side
                            : (selectionDrag.adjustsTop ? anchorY : anchorY - side / 2),
                          width: side, height: side)
        }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom).integral
    }

    private func updateDraftModifiers(_ flags: NSEvent.ModifierFlags) {
        let next = flags.intersection([.shift, .option])
        if next.contains(.shift), !dragModifiers.contains(.shift),
           let start = dragStart, let end = dragEnd {
            let dx = end.x - start.x
            let dy = end.y - start.y
            constraintAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
            let opposite = constraintAxis == .horizontal ? abs(dy) : abs(dx)
            fixedOppositeDimension = opposite > 1 ? opposite : 24 * pointsToImage
        } else if next.contains(.shift), constraintAxis == nil,
                  let start = dragStart, let end = dragEnd {
            let dx = end.x - start.x
            let dy = end.y - start.y
            constraintAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
            fixedOppositeDimension = 24 * pointsToImage
        } else if !next.contains(.shift) {
            constraintAxis = nil
            fixedOppositeDimension = nil
        }
        dragModifiers = next
        needsDisplay = true
    }

    private func resolvedShapeEnd(from start: CGPoint, rawEnd: CGPoint) -> CGPoint {
        guard tool.supportsShapeConstraints else { return rawEnd }
        let dx = rawEnd.x - start.x
        let dy = rawEnd.y - start.y
        if dragModifiers.contains(.option) { return rawEnd }
        if dragModifiers.contains(.shift) {
            let axis = constraintAxis ?? (abs(dx) >= abs(dy) ? ConstraintAxis.horizontal : .vertical)
            let requested = fixedOppositeDimension ?? 24 * pointsToImage
            if axis == .horizontal {
                let available = dy < 0 ? start.y : imageSize.height - start.y
                let fixed = min(requested, available)
                return CGPoint(x: rawEnd.x, y: start.y + (dy < 0 ? -fixed : fixed))
            }
            let available = dx < 0 ? start.x : imageSize.width - start.x
            let fixed = min(requested, available)
            return CGPoint(x: start.x + (dx < 0 ? -fixed : fixed), y: rawEnd.y)
        }
        return rawEnd
    }

    private func resolvedShapeRect(from start: CGPoint, rawEnd: CGPoint) -> CGRect {
        if tool.supportsShapeConstraints, dragModifiers.contains(.option) {
            let dx = rawEnd.x - start.x
            let dy = rawEnd.y - start.y
            let side = max(0, min(max(abs(dx), abs(dy)),
                dx < 0 ? start.x : imageSize.width - start.x,
                dy < 0 ? start.y : imageSize.height - start.y))
            return CGRect(x: dx < 0 ? start.x - side : start.x,
                          y: dy < 0 ? start.y - side : start.y,
                          width: side, height: side)
        }
        let end = resolvedShapeEnd(from: start, rawEnd: rawEnd)
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    override func flagsChanged(with event: NSEvent) {
        if dragStart != nil { updateDraftModifiers(event.modifierFlags) }
        if selectionDrag != nil {
            let next = adjustedSelection(to: selectionLastPoint, modifiers: event.modifierFlags)
            if next != frame {
                isAdjustingSelection = true
                frame = next
                onSelectionChanged?(next, false, selectionDrag == .move)
            }
        }
        super.flagsChanged(with: event)
    }

    private func beginPenNode(at point: CGPoint) {
        if penNodes.count > 2, let first = penNodes.first,
           hypot(point.x - first.point.x, point.y - first.point.y) < 10 * pointsToImage {
            finishPen(closed: true)
            return
        }
        if penNodes.isEmpty { penColor = drawingColor; penWidth = penLineWidthPoints * strokePixelsPerPoint }
        penRedoNodes.removeAll()
        penNodes.append(ScreenshotPenNode(point: point))
        penDraggedNode = penNodes.count - 1
        selectedIndex = nil
        hoveredIndex = nil
        onChange?()
        needsDisplay = true
    }

    private func dragPenControl(to point: CGPoint) {
        guard let index = penDraggedNode, penNodes.indices.contains(index) else { return }
        let anchor = penNodes[index].point
        guard hypot(point.x - anchor.x, point.y - anchor.y) > 2 * pointsToImage else { return }
        penNodes[index].outgoing = point
        penNodes[index].incoming = CGPoint(x: 2 * anchor.x - point.x, y: 2 * anchor.y - point.y)
        needsDisplay = true
    }

    func finishPen(closed: Bool = false) {
        guard !penNodes.isEmpty else { return }
        if penNodes.count > 1 {
            pushUndo()
            annotations.append(ScreenshotAnnotation.pen(penNodes, width: penWidth, closed: closed).colored(penColor))
            selectedIndex = annotations.count - 1
            hoveredIndex = selectedIndex
        }
        penNodes.removeAll()
        penRedoNodes.removeAll()
        penDraggedNode = nil
        onChange?()
        needsDisplay = true
    }

    @discardableResult func cancelPendingAnnotation() -> Bool {
        if cancelElementDrag() { return true }
        guard !penNodes.isEmpty || pendingSticker != nil else { return false }
        cancelDraft()
        pendingSticker = nil
        onChange?()
        return true
    }

    func prepareSticker(_ asset: ScreenshotStickerAsset) {
        finishPen()
        tool = .sticker
        pendingSticker = asset
        selectedIndex = nil
        hoveredIndex = nil
    }

    private func stickerRect(from start: CGPoint, to end: CGPoint, asset: ScreenshotStickerAsset) -> CGRect {
        let dx = end.x - start.x, dy = end.y - start.y
        let isClick = hypot(dx, dy) < 3 * pointsToImage
        let available = isClick ? CGSize(width: imageSize.width * 0.45, height: imageSize.height * 0.45)
            : CGSize(width: max(1, abs(dx)), height: max(1, abs(dy)))
        let scale = min(available.width / CGFloat(asset.width), available.height / CGFloat(asset.height))
        let size = CGSize(width: max(1, CGFloat(asset.width) * scale), height: max(1, CGFloat(asset.height) * scale))
        return CGRect(x: min(imageSize.width - size.width, max(0, dx < 0 ? start.x - size.width : start.x)),
                      y: min(imageSize.height - size.height, max(0, dy < 0 ? start.y - size.height : start.y)),
                      width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) {
        strokeGestureIndex = nil
        let location = convert(event.locationInWindow, from: nil)
        if isCropping { beginCropDrag(at: location); return }
        if activeTextField != nil { commitText() }
        if tool == .pen, !penNodes.isEmpty, let point = imagePoint(location, requireInside: true) {
            if event.clickCount >= 2 { finishPen() } else { beginPenNode(at: point) }
            return
        }
        // The selection's move hit area covers the image. Finish a second
        // click before that drag path consumes it; text keeps its edit action.
        if contentInset == 0, event.clickCount >= 2, !event.modifierFlags.contains(.option),
           imageRect.contains(location), activeTextField == nil {
            let editableText = elementHit(at: location).map { hit in
                switch annotations[hit.index].shape {
                case .text, .styledText, .translation: return true
                default: return false
                }
            } ?? false
            if !editableText {
                onDoubleClick?()
                return
            }
        }
        let hit = elementHit(at: location, copying: event.modifierFlags.contains(.option))
        if contentInset == 0, !isAdjustingSelection,
           let container = superview, let handle = selectionDrag(at: location),
           !isSelectedArrowBoxGrip(hit, at: location) {
            selectionDrag = handle
            selectionStartFrame = frame
            selectionStartPoint = container.convert(event.locationInWindow, from: nil)
            selectionLastPoint = selectionStartPoint
            selectionConstraintHorizontal = nil
            return
        }
        if tool == .sticker, pendingSticker != nil,
           let point = imagePoint(location, requireInside: true) {
            dragStart = point; dragEnd = point
            return
        }
        if let hit,
           let point = imagePoint(location, requireInside: true) {
            selectedIndex = hit.index
            activeBezierIndex = {
                if case .bezierArrow = annotations[hit.index].shape { return hit.index }
                if case .sizedBezierArrow = annotations[hit.index].shape { return hit.index }
                return nil
            }()
            if event.clickCount >= 2, !event.modifierFlags.contains(.option) {
                switch annotations[hit.index].shape {
                case .text(let origin, _, _), .styledText(let origin, _, _, _, _):
                    beginText(at: origin, viewPoint: viewPoint(origin),
                              editing: hit.index, translationLine: nil)
                case .translation(let lines):
                    if let line = hit.translationLine, lines.indices.contains(line) {
                        let rect = translatedRect(lines[line])
                        beginText(at: CGPoint(x: rect.minX, y: rect.minY),
                                  viewPoint: viewPoint(rect.origin),
                                  editing: hit.index, translationLine: line)
                    }
                default: break
                }
                needsDisplay = true
                return
            }
            elementDrag = ElementDrag(hit: hit, original: annotations[hit.index],
                                      start: point, before: annotations,
                                      duplicates: hit.handle == .body && event.modifierFlags.contains(.option))
            elementDragChanged = false
            elementDragCopyIndex = nil
            needsDisplay = true
            return
        }
        if event.clickCount >= 2, tool != .number, tool != .highlighter,
           imageRect.contains(location), activeTextField == nil {
            onDoubleClick?()
            return
        }
        selectedIndex = nil
        activeBezierIndex = nil
        guard let point = imagePoint(location, requireInside: true) else { return }
        if tool == .pen { beginPenNode(at: point); return }
        if tool == .sticker { return }
        if tool == .text {
            beginText(at: point, viewPoint: location, editing: nil,
                      translationLine: nil)
            return
        }
        if tool == .number {
            let radius = max(12, 12 * imageSize.width / max(1, imageRect.width))
            let borderWidth = numberBorderWidthPoints > 0 ? numberBorderWidthPoints * pointsToImage : nil
            pushUndo()
            annotations.append(.number(point, nextNumber, radius, borderWidth: borderWidth)
                .colored(drawingColor))
            selectedIndex = annotations.count - 1
            onChange?()
            needsDisplay = true
            return
        }
        dragStart = point
        dragEnd = point
        dragModifiers = event.modifierFlags.intersection([.shift, .option])
        constraintAxis = nil
        fixedOppositeDimension = nil
        if tool == .highlighter {
            highlighterPoints = [point]
            highlighterWidth = highlighterLineWidthPoints * pointsToImage
        }
        if tool == .brush {
            brushPoints = [point]
            brushWidth = brushLineWidthPoints * strokePixelsPerPoint
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isCropping { updateCropDrag(at: convert(event.locationInWindow, from: nil)); return }
        if penDraggedNode != nil, let point = imagePoint(convert(event.locationInWindow, from: nil)) {
            dragPenControl(to: point)
            return
        }
        if let elementDrag, annotations.indices.contains(elementDrag.hit.index),
           let point = imagePoint(convert(event.locationInWindow, from: nil)) {
            let delta = CGPoint(x: point.x - elementDrag.start.x,
                                y: point.y - elementDrag.start.y)
            if elementDrag.duplicates, elementDragCopyIndex == nil {
                guard hypot(delta.x, delta.y) >= 2 * pointsToImage else { return }
                annotations.append(elementDrag.original)
                elementDragCopyIndex = annotations.count - 1
                selectedIndex = elementDragCopyIndex
                hoveredIndex = selectedIndex
                if activeBezierIndex == elementDrag.hit.index { activeBezierIndex = elementDragCopyIndex }
            }
            let index = elementDragCopyIndex ?? elementDrag.hit.index
            annotations[index] = changed(
                elementDrag.original, handle: elementDrag.hit.handle, delta: delta,
                modifiers: event.modifierFlags)
            if elementDrag.hit.handle == .magnification,
               let lens = annotations[elementDrag.hit.index].magnifierGeometry {
                magnifierMagnification = lens.magnification
                showStrokeHint(String(format: "%.1f×", lens.magnification),
                               near: convert(event.locationInWindow, from: nil))
            }
            elementDragChanged = elementDragCopyIndex != nil || hypot(delta.x, delta.y) > 0.01
            (elementDrag.duplicates ? NSCursor.dragCopy : cursor(for: elementDrag.hit.handle)).set()
            needsDisplay = true
            return
        }
        if selectionDrag != nil, let container = superview {
            selectionLastPoint = container.convert(event.locationInWindow, from: nil)
            let next = adjustedSelection(to: selectionLastPoint, modifiers: event.modifierFlags)
            if next != frame {
                isAdjustingSelection = true
                frame = next
                onSelectionChanged?(next, false, selectionDrag == .move)
            }
            return
        }
        guard dragStart != nil else { return }
        dragEnd = imagePoint(convert(event.locationInWindow, from: nil))
        updateDraftModifiers(event.modifierFlags)
        if tool == .highlighter, let point = dragEnd {
            appendHighlighterPoint(point)
        }
        if tool == .brush, let point = dragEnd {
            appendBrushPoint(point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isCropping { finishCropDrag(at: convert(event.locationInWindow, from: nil)); return }
        if penDraggedNode != nil {
            if let point = imagePoint(convert(event.locationInWindow, from: nil)) { dragPenControl(to: point) }
            penDraggedNode = nil
            return
        }
        if let elementDrag {
            let changed = elementDragChanged
            if changed {
                pushUndo(elementDrag.before)
            }
            self.elementDrag = nil
            elementDragChanged = false
            elementDragCopyIndex = nil
            if changed { onChange?() }
            onElementClipboardChanged?()
            return
        }
        if selectionDrag != nil {
            let moving = selectionDrag == .move
            selectionDrag = nil
            if isAdjustingSelection { onSelectionChanged?(frame, true, moving) }
            return
        }
        guard let start = dragStart,
              let rawEnd = imagePoint(convert(event.locationInWindow, from: nil)) else {
            cancelDraft()
            return
        }
        dragEnd = rawEnd
        updateDraftModifiers(event.modifierFlags)
        let end = resolvedShapeEnd(from: start, rawEnd: rawEnd)
        defer { cancelDraft() }
        let rect = resolvedShapeRect(from: start, rawEnd: rawEnd)
        let before = annotations
        switch tool {
        case .sticker:
            guard let asset = pendingSticker else { return }
            annotations.append(.sticker(stickerRect(from: start, to: rawEnd, asset: asset), asset))
            pendingSticker = nil
        case .arrow where hypot(end.x - start.x, end.y - start.y) >= 12:
            guard let arrow = arrowAnnotation(from: start, to: end) else { return }
            annotations.append(arrow)
            activeBezierIndex = arrowStyle == .bezier ? annotations.count - 1 : nil
        case .magnifier:
            guard let lens = magnifier(from: start, to: rawEnd) else { return }
            annotations.append(lens)
        case .spotlight where rect.width >= 8 && rect.height >= 8:
            annotations.append(.spotlight(rect))
        case .mosaic where rect.width >= 8 && rect.height >= 8:
            annotations.append(.obscure(rect, mode: obscureMode, strength: obscureStrength))
        case .rectangle, .discard:
            guard rect.width >= 8, rect.height >= 8 else { return }
            annotations.append(boxAnnotation(in: rect))
        case .highlighter:
            appendHighlighterPoint(end)
            let points = highlighterPath(from: start, to: end)
            guard points.count > 1, points.contains(where: { $0 != start }) else { return }
            annotations.append(.highlighter(points, highlighterWidth, opacity: highlighterOpacity))
        case .brush:
            appendBrushPoint(end)
            let points = dragModifiers.contains(.shift) ? [start, end] : brushPoints
            guard points.count > 1 else { return }
            annotations.append(.brush(points, brushWidth))
        case .ellipse where rect.width >= 8 && rect.height >= 8:
            annotations.append(.styledEllipse(rect, style: ellipseStyle,
                                               width: ellipseLineWidth))
        default:
            return
        }
        if tool != .mosaic, tool != .spotlight, tool != .magnifier, tool != .sticker, let mark = annotations.last {
            annotations[annotations.count - 1] = mark.colored(drawingColor)
        }
        pushUndo(before)
        selectedIndex = annotations.count - 1
        hoveredIndex = selectedIndex
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        guard !isInputSuspended else { return }
        if handleElementClipboardShortcut(event) { return }
        if isCropping, event.keyCode == 53 { cancelCrop(); return }
        if isCropping, [36, 76].contains(event.keyCode) { _ = applyCrop(); return }
        if event.keyCode == 53 {
            if !cancelElementDrag() { cancelDraft() }
            return
        }
        if [36, 76].contains(event.keyCode), isBuildingPenPath { finishPen(); return }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelectedElement()
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: nudgeSelectedElement(dx: -step, dy: 0); return
        case 124: nudgeSelectedElement(dx: step, dy: 0); return
        case 125: nudgeSelectedElement(dx: 0, dy: -step); return
        case 126: nudgeSelectedElement(dx: 0, dy: step); return
        default: break
        }
        super.keyDown(with: event)
    }

    private func magnifier(from start: CGPoint, to end: CGPoint) -> ScreenshotAnnotation? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        guard hypot(dx, dy) > 0 else { return nil }
        var width = abs(dx)
        var height = abs(dy)
        if dragModifiers.contains(.shift) { width = max(width, height); height = width }
        let rect = CGRect(x: dx < 0 ? start.x - width : start.x,
                          y: dy < 0 ? start.y - height : start.y,
                          width: max(1, width), height: max(1, height))
        return magnifierStyle.annotation(in: rect, magnification: magnifierMagnification)
    }

    var selectedMagnifierStyle: ScreenshotMagnifierStyle? {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return nil }
        return annotations[selectedIndex].magnifierGeometry?.style
    }

    func chooseMagnifierStyle(_ style: ScreenshotMagnifierStyle) {
        commitText()
        magnifierStyle = style
        guard let index = selectedIndex, annotations.indices.contains(index),
              let lens = annotations[index].magnifierGeometry, lens.style != style else { return }
        pushUndo()
        annotations[index] = style.annotation(in: lens.rect, magnification: lens.magnification)
        onChange?()
        needsDisplay = true
    }

    private func beginText(at point: CGPoint, viewPoint: CGPoint,
                           editing index: Int?, translationLine: Int?) {
        let existing: String
        let pointSize: CGFloat = translationLine == nil ? 18 : 16
        textFontSize = pointSize * pointsToImage
        editingTextStyle = textStyle
        editingOutlineWidth = index == nil && textOutlineWidthPoints > 0
            ? textOutlineWidthPoints * pointsToImage : nil
        editingColor = index.flatMap { annotations.indices.contains($0) ? annotations[$0].color : nil }
        if index == nil, annotationColor != .red || textStyle.foreground != .systemRed {
            editingColor = annotationColor
        }
        editingLegacyText = false
        if let index, annotations.indices.contains(index) {
            switch annotations[index].shape {
            case .text(_, let text, let size):
                existing = text
                textFontSize = size
                editingTextStyle = .plain
                editingLegacyText = true
            case .styledText(_, let text, let size, let style, let outlineWidth):
                existing = text
                textFontSize = size
                editingTextStyle = style
                editingOutlineWidth = outlineWidth
            case .translation(let lines):
                existing = translationLine.flatMap { lines.indices.contains($0) ? lines[$0].text : nil } ?? ""
                if let line = translationLine, lines.indices.contains(line),
                   let size = lines[line].fontSize { textFontSize = size }
                editingTextStyle = .plain
            default: existing = ""
            }
        } else { existing = "" }
        let font = editingFont
        let height = ceil(font.ascender - font.descender + font.leading) + 8
        let field = NSTextField(frame: CGRect(x: viewPoint.x - 2,
            y: viewPoint.y - height + ceil(font.ascender), width: 160, height: height))
        // NSTextField vertically centers its placeholder independently of the
        // field editor's first-glyph baseline. Draw the hint on the canvas at
        // the exact saved baseline instead, so the first keystroke cannot jump.
        field.placeholderString = nil
        field.setAccessibilityLabel(index == nil ? "输入文字，回车添加" : "修改文字，回车确认")
        field.stringValue = existing
        field.font = font
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = translationLine != nil
        if translationLine != nil { field.backgroundColor = .textBackgroundColor }
        field.focusRingType = .none
        // A single-line cell can clip tall glyphs at 18 points. Keep the
        // editor unwrapped, with enough room for the font's full ascent.
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.target = self
        field.action = #selector(commitText)
        addSubview(field)
        textLocation = point
        editingTextIndex = index
        editingTranslationLine = translationLine
        activeTextField = field
        onTextEditingChanged?()
        // Shape tools do not take focus from the source app. Text entry does
        // need a key panel so the new field can receive typed characters.
        if let panel = window as? NSPanel { panel.makeKeyAndOrderFront(nil) }
        window?.makeFirstResponder(field)
        observeTextInput()
        updateTextEditor()
        onChange?()
    }

    var selectedColor: ScreenshotAnnotationColor? {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return nil }
        let mark = annotations[selectedIndex]
        switch mark.shape {
        case .mosaic, .obscure, .spotlight, .magnifier, .ellipticalMagnifier, .rectangularMagnifier, .translation, .sticker: return nil
        default: return mark.color ?? .red
        }
    }

    func chooseColor(_ color: ScreenshotAnnotationColor) {
        commitText()
        toolColors[tool] = color
        needsDisplay = true
        guard let selectedIndex, annotations.indices.contains(selectedIndex),
              selectedColor != nil else { return }
        pushUndo()
        annotations[selectedIndex] = annotations[selectedIndex].colored(color)
        onChange?()
    }

    var selectedHighlighterOpacity: Int? {
        guard let selectedIndex, annotations.indices.contains(selectedIndex),
              case .highlighter(_, _, let opacity) = annotations[selectedIndex].shape else { return nil }
        return opacity ?? 35
    }

    func setHighlighterOpacity(_ opacity: Int, updateSelection: Bool = false) {
        let level = min(100, max(10, opacity))
        highlighterOpacity = level
        if updateSelection, let selectedIndex, let previous = selectedHighlighterOpacity,
           previous != level {
            let mark = annotations[selectedIndex]
            if case .highlighter(let points, let width, _) = mark.shape {
                pushUndo()
                annotations[selectedIndex] = .highlighter(points, width, opacity: level)
                    .colored(mark.color)
                onChange?()
            }
        }
        needsDisplay = true
    }

    var selectedObscure: (CGRect, ScreenshotObscureMode, Int)? {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return nil }
        switch annotations[selectedIndex].shape {
        case .mosaic(let rect): return (rect, .mosaic, 3)
        case .obscure(let rect, let mode, let strength): return (rect, mode, strength)
        default: return nil
        }
    }

    func chooseObscure(_ mode: ScreenshotObscureMode, strength: Int? = nil) {
        commitText()
        obscureMode = mode
        if let strength { obscureStrengths[mode] = strength }
        if let selectedIndex, let (rect, oldMode, oldStrength) = selectedObscure {
            let level = strength ?? (oldMode == mode ? oldStrength : obscureStrength)
            if mode != oldMode || level != oldStrength {
                pushUndo()
                annotations[selectedIndex] = .obscure(rect, mode: mode, strength: level)
                onChange?()
            }
        }
        needsDisplay = true
    }

    private var editingText: String {
        guard let field = activeTextField else { return "" }
        return activeTextEditor?.string ?? field.stringValue
    }

    private var activeTextEditor: NSTextView? {
        guard let field = activeTextField else { return nil }
        // IME candidate UI may temporarily change the first responder. Keep
        // reading this input session's editor, whose string includes marked
        // text, rather than the control's still-uncommitted stringValue.
        return (field.currentEditor() as? NSTextView) ?? observedTextInputEditor
    }

    private var textPlaceholder: String {
        editingTextIndex == nil ? "输入文字，回车添加" : "修改文字，回车确认"
    }

    private var shouldShowTextPlaceholder: Bool {
        guard let field = activeTextField else { return false }
        if let editor = activeTextEditor {
            return editor.string.isEmpty && !editor.hasMarkedText()
        }
        return field.stringValue.isEmpty
    }

    private func observeTextInput() {
        guard let editor = activeTextField?.currentEditor() as? NSTextView,
              let storage = editor.textStorage,
              observedTextInputStorage !== storage else { return }
        stopObservingTextInput()
        observedTextInputEditor = editor
        observedTextInputStorage = storage
        NotificationCenter.default.addObserver(self, selector: #selector(textInputStorageDidChange(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: storage)
    }

    private func stopObservingTextInput() {
        NotificationCenter.default.removeObserver(self,
            name: NSTextStorage.didProcessEditingNotification, object: observedTextInputStorage)
        observedTextInputEditor = nil
        observedTextInputStorage = nil
        pendingTextInputRefresh?.cancel()
        pendingTextInputRefresh = nil
    }

    @objc private func textInputStorageDidChange(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage === observedTextInputStorage,
              storage.editedMask.contains(.editedCharacters),
              let field = activeTextField else { return }
        // Marked text (such as unconfirmed Pinyin) can change before the
        // control's did-change callback. Invalidate the canvas as soon as its characters
        // change, otherwise the old hint stays painted behind the field editor.
        needsDisplay = true
        pendingTextInputRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self, weak field] in
            guard let self, let field, self.activeTextField === field else { return }
            self.pendingTextInputRefresh = nil
            self.updateTextEditor()
        }
        pendingTextInputRefresh = refresh
        // Text storage is still processing this edit. Defer layout/attribute
        // changes until that transaction ends to preserve the IME's marked
        // range and candidate selection rather than re-entering TextKit.
        DispatchQueue.main.async(execute: refresh)
    }

    private var editingFont: NSFont {
        let size = textFontSize / pointsToImage
        return editingLegacyText ? ScreenshotTextRendering.legacyFont(size: size)
            : ScreenshotTextRendering.font(size: size)
    }

    /// NSTextField's field editor has its own padding and flipped coordinates.
    /// Align its actual first-glyph baseline with the saved image baseline;
    /// matching only the enclosing text field's frame shifts text on commit.
    private func editorBaseline(in field: NSTextField) -> CGPoint? {
        guard let editor = activeTextEditor,
              let layout = editor.layoutManager,
              let container = editor.textContainer else { return nil }
        layout.ensureLayout(for: container)
        var glyph = CGPoint(x: container.lineFragmentPadding,
                            y: ceil(field.font?.ascender ?? 16))
        if layout.numberOfGlyphs > 0 {
            glyph = layout.location(forGlyphAt: 0)
            let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            glyph.x += line.minX
            glyph.y += line.minY
        }
        glyph.x += editor.textContainerOrigin.x
        glyph.y += editor.textContainerOrigin.y
        return convert(glyph, from: editor)
    }

    private func updateTextEditor() {
        guard let field = activeTextField, let textLocation else { return }
        let size = textFontSize / pointsToImage
        let text = editingText
        let foreground: NSColor = editingTranslationLine == nil
            ? (editingColor?.color ?? editingTextStyle.foreground) : .labelColor
        let attributes = ScreenshotTextRendering.attributes(size: size, style: editingTextStyle,
            fontOverride: editingFont, foregroundOverride: foreground)
        field.font = editingFont
        field.textColor = foreground
        if let editor = activeTextEditor {
            editor.typingAttributes = attributes
            editor.insertionPointColor = foreground
            // Attribute edits preserve the selection and Chinese IME's marked
            // text; never replace the editor's string while the user types.
            editor.textStorage?.addAttributes(attributes,
                range: NSRange(location: 0, length: (text as NSString).length))
        } else {
            field.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        }
        let textBounds = ScreenshotTextRendering.bounds(at: .zero, text: text, size: size,
                                                        fontOverride: editingFont)
        // Fit the complete line, so the native field editor does not scroll its
        // text horizontally and then jump back when the annotation is saved.
        field.setFrameSize(CGSize(width: max(160, ceil(textBounds.width) + 12),
                                  height: max(24, ceil(textBounds.height) + 8)))
        field.layoutSubtreeIfNeeded()
        let anchor = viewPoint(textLocation)
        if let baseline = editorBaseline(in: field) {
            field.setFrameOrigin(CGPoint(x: field.frame.minX + anchor.x - baseline.x,
                                          y: field.frame.minY + anchor.y - baseline.y))
        }
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) { updateTextEditor() }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === activeTextField else { return }
        observeTextInput()
    }

    func chooseTextStyle(_ style: ScreenshotTextStyle) {
        commitText()
        textStyle = style
        guard let index = selectedIndex, annotations.indices.contains(index) else { return }
        let updated: ScreenshotAnnotation
        switch annotations[index].shape {
        case .text(let point, let text, let size):
            updated = .styledText(point, text, fontSize: size, style: style)
        case .styledText(let point, let text, let size, let previous, let outlineWidth) where previous != style:
            updated = .styledText(point, text, fontSize: size, style: style, outlineWidth: outlineWidth)
        default: return
        }
        pushUndo()
        annotations[index] = updated.colored(annotations[index].color)
        onChange?()
        needsDisplay = true
    }

    var selectedTextStyle: ScreenshotTextStyle? {
        guard let index = selectedIndex, annotations.indices.contains(index) else { return nil }
        switch annotations[index].shape {
        case .text: return .plain
        case .styledText(_, _, _, let style, _): return style
        default: return nil
        }
    }

    @objc private func commitText() {
        guard let field = activeTextField else { return }
        let text = editingText
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        stopObservingTextInput()
        activeTextField = nil
        onTextEditingChanged?()
        field.removeFromSuperview()
        if let index = editingTextIndex, annotations.indices.contains(index), hasText {
            switch annotations[index].shape {
            case .text(let point, let old, let size) where text != old:
                pushUndo()
                annotations[index] = ScreenshotAnnotation.text(point, text, fontSize: size).colored(editingColor)
            case .styledText(let point, let old, let size, let style, let outlineWidth) where text != old:
                pushUndo()
                annotations[index] = ScreenshotAnnotation.styledText(point, text, fontSize: size,
                    style: style, outlineWidth: outlineWidth).colored(editingColor)
            case .translation(var lines):
                if let line = editingTranslationLine, lines.indices.contains(line),
                   lines[line].text != text {
                    pushUndo()
                    lines[line].text = text
                    annotations[index] = .translation(lines)
                }
            default: break
            }
        } else if let textLocation, hasText {
            pushUndo()
            annotations.append(.styledText(textLocation, text, fontSize: textFontSize,
                style: editingTextStyle, outlineWidth: editingOutlineWidth).colored(editingColor))
            selectedIndex = annotations.count - 1
        }
        self.textLocation = nil
        editingTextIndex = nil
        editingTranslationLine = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
        onChange?()
    }

    func discardText() {
        guard let field = activeTextField else { return }
        stopObservingTextInput()
        activeTextField = nil
        onTextEditingChanged?()
        field.removeFromSuperview()
        textLocation = nil
        editingTextIndex = nil
        editingTranslationLine = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
        onChange?()
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func undo() {
        if isCropping { cancelCrop(); return }
        if let node = penNodes.popLast() {
            penRedoNodes.append(node); penDraggedNode = nil
            onChange?(); needsDisplay = true; return
        }
        strokeGestureIndex = nil
        if activeTextField != nil { commitText() }
        guard let prior = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(prior)
        clearInvalidSelection()
        onChange?()
        needsDisplay = true
    }

    func redo() {
        if isCropping { cancelCrop(); return }
        if let node = penRedoNodes.popLast() {
            penNodes.append(node)
            onChange?(); needsDisplay = true; return
        }
        strokeGestureIndex = nil
        if activeTextField != nil { commitText() }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
        clearInvalidSelection()
        onChange?()
        needsDisplay = true
    }

    private func restore(_ snapshot: Snapshot) {
        let imageChanged = image !== snapshot.image
        image = snapshot.image
        annotations = snapshot.annotations
        hasImageEdits = snapshot.hasImageEdits
        if imageChanged {
            obscuredImages.removeAllObjects()
            deselectElement()
            onImageSizeChanged?()
        }
    }

    var hasSelectedElement: Bool {
        selectedIndex.map { annotations.indices.contains($0) } == true
    }

    private var canUseElementClipboard: Bool {
        guard !isInputSuspended, !isCropping, activeTextField == nil,
              !isBuildingPenPath, pendingSticker == nil, elementDrag == nil,
              dragStart == nil, selectionDrag == nil, !isAdjustingSelection else { return false }
        if let editor = window?.firstResponder as? NSTextView,
           editor.isEditable || editor.hasMarkedText() { return false }
        return true
    }

    var canCopySelectedElement: Bool { canUseElementClipboard && hasSelectedElement }

    @discardableResult
    func copySelectedElement(to board: NSPasteboard = .general) -> Bool {
        guard canCopySelectedElement, let selectedIndex else { return false }
        let item = annotations[selectedIndex]
        let version = if case .arrowBox = item.shape { 10 } else { 9 }
        let document = ScreenshotAnnotationDocument(version: version, imageWidth: image.width,
            imageHeight: image.height, annotations: [item])
        guard let data = try? JSONEncoder().encode(document), data.count <= 48 * 1024 * 1024 else { return false }
        board.clearContents()
        let copied = board.setData(data, forType: Self.elementPasteboardType)
        onElementClipboardChanged?()
        return copied
    }

    @discardableResult
    func pasteElement(from board: NSPasteboard = .general) -> Bool {
        guard canUseElementClipboard, let data = board.data(forType: Self.elementPasteboardType),
              data.count <= 48 * 1024 * 1024,
              let document = try? JSONDecoder().decode(ScreenshotAnnotationDocument.self, from: data),
              ScreenshotAnnotationDocument.supportedVersions.contains(document.version),
              document.imageWidth > 0, document.imageHeight > 0,
              document.annotations.count == 1 else { return false }
        // OCR rectangles use a top-left origin. Other elements use bottom-left
        // image pixels, which stay unchanged when pasting into another image.
        func adjustedOrigin(_ item: ScreenshotAnnotation) -> ScreenshotAnnotation {
            switch item {
            case .colored(let shape, let color): return adjustedOrigin(shape).colored(color)
            case .translation(let lines):
                return .translation(lines.map { line in
                    var next = line
                    next.sourceRect = next.sourceRect.offsetBy(dx: 0,
                        dy: CGFloat(image.height) - CGFloat(document.imageHeight))
                    return next
                })
            default: return item
            }
        }
        let item = adjustedOrigin(document.annotations[0])
        let area = bounds(of: item).standardized
        guard !area.isNull, !area.isEmpty,
              [area.minX, area.minY, area.maxX, area.maxY].allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }) else { return false }
        let repeated = lastElementPasteboard == board.name && lastElementPasteboardChange == board.changeCount
        let count = repeated ? min(1000, elementPasteCount + 1) : 1
        let offset = CGFloat(count) * 12 * pointsToImage
        func origin(_ value: CGFloat, length: CGFloat, available: CGFloat) -> CGFloat {
            length <= available ? min(max(0, value), available - length) : (available - length) / 2
        }
        let delta = CGPoint(x: origin(area.minX + offset, length: area.width, available: imageSize.width) - area.minX,
                            y: origin(area.minY - offset, length: area.height, available: imageSize.height) - area.minY)
        pushUndo()
        annotations.append(changed(item, handle: .body, delta: delta))
        selectedIndex = annotations.count - 1
        hoveredIndex = selectedIndex
        activeBezierIndex = {
            switch item.shape { case .bezierArrow, .sizedBezierArrow: return selectedIndex; default: return nil }
        }()
        lastElementPasteboard = board.name
        lastElementPasteboardChange = board.changeCount
        elementPasteCount = count
        onChange?()
        needsDisplay = true
        return true
    }

    @discardableResult
    func handleElementClipboardShortcut(_ event: NSEvent, pasteboard: NSPasteboard = .general) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return false }
        switch event.keyCode {
        case 8: return copySelectedElement(to: pasteboard)
        case 9: return pasteElement(from: pasteboard)
        default: return false
        }
    }

    @objc func copy(_ sender: Any?) { _ = copySelectedElement() }
    @objc func paste(_ sender: Any?) { _ = pasteElement() }

    @discardableResult
    private func cancelElementDrag() -> Bool {
        guard let drag = elementDrag else { return false }
        annotations = drag.before
        elementDrag = nil
        elementDragCopyIndex = nil
        elementDragChanged = false
        selectedIndex = drag.hit.index
        hoveredIndex = selectedIndex
        activeBezierIndex = {
            switch drag.original.shape { case .bezierArrow, .sizedBezierArrow: return selectedIndex; default: return nil }
        }()
        onChange?()
        needsDisplay = true
        return true
    }

    func deselectElement() {
        selectedIndex = nil
        hoveredIndex = nil
        activeBezierIndex = nil
        needsDisplay = true
    }

    func deleteSelectedElement() {
        if !penNodes.isEmpty { undo(); return }
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
        pushUndo()
        annotations.remove(at: selectedIndex)
        deselectElement()
        onChange?()
    }

    func nudgeSelectedElement(dx: CGFloat, dy: CGFloat) {
        guard let selectedIndex, annotations.indices.contains(selectedIndex) else { return }
        pushUndo()
        annotations[selectedIndex] = changed(annotations[selectedIndex], handle: .body,
            delta: CGPoint(x: dx, y: dy))
        onChange?()
        needsDisplay = true
    }

    private func clearInvalidSelection() {
        if let selectedIndex, !annotations.indices.contains(selectedIndex) {
            self.selectedIndex = nil
        }
        if let hoveredIndex, !annotations.indices.contains(hoveredIndex) {
            self.hoveredIndex = nil
        }
        if let activeBezierIndex, !annotations.indices.contains(activeBezierIndex) {
            self.activeBezierIndex = nil
        }
    }

    func cancelDraft() {
        penNodes.removeAll()
        penRedoNodes.removeAll()
        penDraggedNode = nil
        dragStart = nil
        dragEnd = nil
        dragModifiers = []
        constraintAxis = nil
        fixedOppositeDimension = nil
        highlighterPoints.removeAll()
        brushPoints.removeAll()
        needsDisplay = true
        onElementClipboardChanged?()
    }

    private func highlighterPath(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        dragModifiers.contains(.shift) ? [start, end] : highlighterPoints
    }

    private func appendHighlighterPoint(_ point: CGPoint) {
        if let previous = highlighterPoints.last,
           hypot(point.x - previous.x, point.y - previous.y) < 1 { return }
        highlighterPoints.append(point)
    }

    private func appendBrushPoint(_ point: CGPoint) {
        if let previous = brushPoints.last,
           hypot(point.x - previous.x, point.y - previous.y) < 1 { return }
        brushPoints.append(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if contentInset > 0 {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        let rect = imageRect
        guard !rect.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        if !isAdjustingSelection {
            // An isolated window may have transparent corners and a native
            // shadow. Never composite those pixels directly over the same
            // live window: its edge/shadow would appear a second time. This
            // backing is editor-only; render()/export retain the original alpha.
            drawTransparencyBackground(in: rect)
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / imageSize.width,
                            y: rect.height / imageSize.height)
            let compositesImageEffects = ([.mosaic, .spotlight, .magnifier].contains(tool) && dragStart != nil)
                || annotations.contains {
                    switch $0.shape {
                    case .mosaic, .obscure, .spotlight, .magnifier, .ellipticalMagnifier, .rectangularMagnifier: return true
                    default: return false
                    }
                }
            if compositesImageEffects { context.beginTransparencyLayer(auxiliaryInfo: nil) }
            render(in: context, includeDraft: true)
            if compositesImageEffects { context.endTransparencyLayer() }
            context.restoreGState()
        }
        (contentInset == 0 ? NSColor.systemBlue : NSColor.separatorColor).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = contentInset == 0 ? 2 : 1
        border.stroke()
        if isCropping {
            drawCropOverlay()
            return
        }
        if contentInset == 0 {
            NSColor.systemBlue.setFill()
            for (_, point) in selectionHandles {
                NSBezierPath(roundedRect: CGRect(x: point.x - 5, y: point.y - 5,
                                                 width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
            }
        }
        if let activeBezier {
            let start = viewPoint(activeBezier.start)
            let control = viewPoint(activeBezier.control)
            let end = viewPoint(activeBezier.end)
            let guide = NSBezierPath()
            guide.move(to: start)
            guide.line(to: control)
            guide.line(to: end)
            guide.lineWidth = 1
            guide.setLineDash([4, 4], count: 2, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.55).setStroke()
            guide.stroke()
            for (point, isControl) in [(start, false), (control, true), (end, false)] {
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 5, y: point.y - 5,
                                                         width: 10, height: 10))
                (isControl ? NSColor.systemBlue : NSColor.white).setFill()
                handle.fill()
                NSColor.systemBlue.setStroke()
                handle.lineWidth = 1.5
                handle.stroke()
            }
        }
        drawPenGuides(penNodes)
        // Editing guides belong to the editor view, never to renderedImage().
        if let index = hoveredIndex ?? selectedIndex, annotations.indices.contains(index),
           activeTextField == nil {
            let item = annotations[index]
            if case .pen(let nodes, _, _) = item.shape { drawPenGuides(nodes) }
            let itemBounds = bounds(of: item)
            let handleRect = elementHandleRect(for: item, around: itemBounds)
            let outline = viewRect(handleRect)
            let showsBounds: Bool
            switch item.shape {
            case .arrow, .bezierArrow, .sizedArrow, .sizedBezierArrow, .arrowBox, .pen: showsBounds = false
            case .magnifier, .ellipticalMagnifier, .rectangularMagnifier:
                showsBounds = handleRect != itemBounds
            default: showsBounds = true
            }
            if showsBounds, !outline.isNull, !outline.isEmpty {
                let path = NSBezierPath(rect: outline.insetBy(dx: -3, dy: -3))
                path.lineWidth = 1
                path.setLineDash([4, 3], count: 2, phase: 0)
                NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
                path.stroke()
            }
            for (kind, point) in handles(for: item) {
                let center = viewPoint(point)
                if kind == .magnification {
                    let diamond = NSBezierPath()
                    diamond.move(to: CGPoint(x: center.x, y: center.y + 7))
                    diamond.line(to: CGPoint(x: center.x + 6, y: center.y))
                    diamond.line(to: CGPoint(x: center.x, y: center.y - 7))
                    diamond.line(to: CGPoint(x: center.x - 6, y: center.y))
                    diamond.close()
                    NSColor.systemBlue.setFill()
                    diamond.fill()
                    NSColor.white.setStroke()
                    diamond.lineWidth = 1
                    diamond.stroke()
                    if let lens = item.magnifierGeometry {
                        let text = String(format: "%.1f×", lens.magnification)
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                            .foregroundColor: NSColor.white,
                            .backgroundColor: NSColor.systemBlue
                        ]
                        let size = (text as NSString).size(withAttributes: attributes)
                        (text as NSString).draw(at: CGPoint(
                            x: center.x - size.width / 2, y: center.y + 12),
                            withAttributes: attributes)
                    }
                    continue
                }
                let handle = NSBezierPath(ovalIn: CGRect(
                    x: center.x - 5, y: center.y - 5, width: 10, height: 10))
                NSColor.white.setFill()
                handle.fill()
                NSColor.systemBlue.setStroke()
                handle.lineWidth = 1.5
                handle.stroke()
            }
        }
    }

    private func drawCropOverlay() {
        guard let cropRect else { return }
        let rect = viewRect(cropRect)
        let shade = NSBezierPath(rect: imageRect)
        shade.appendRect(rect)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        shade.fill()
        let grid = NSBezierPath()
        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
            grid.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            grid.line(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            grid.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            grid.line(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        NSColor.white.withAlphaComponent(0.45).setStroke()
        grid.lineWidth = 1
        grid.stroke()
        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2
        outline.stroke()
        for (_, point) in handles(in: rect) {
            let handle = NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4,
                                                         width: 8, height: 8), xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1.5
            handle.stroke()
        }
        let pixels = ScreenshotCropGeometry.pixelRect(cropRect, in: imageSize)
        let label = NSAttributedString(string: "\(Int(pixels?.width ?? 0)) × \(Int(pixels?.height ?? 0))",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                         .foregroundColor: NSColor.white])
        let size = label.size()
        let plate = CGRect(x: min(bounds.maxX - size.width - 12, max(0, rect.midX - size.width / 2 - 6)),
                           y: max(0, rect.minY - size.height - 15),
                           width: size.width + 12, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 5, yRadius: 5).fill()
        label.draw(at: CGPoint(x: plate.minX + 6, y: plate.minY + 4))
    }

    private func drawPenGuides(_ nodes: [ScreenshotPenNode]) {
        NSColor.systemBlue.withAlphaComponent(0.65).setStroke()
        for node in nodes {
            let anchor = viewPoint(node.point)
            let guide = NSBezierPath()
            if let incoming = node.incoming { guide.move(to: anchor); guide.line(to: viewPoint(incoming)) }
            if let outgoing = node.outgoing { guide.move(to: anchor); guide.line(to: viewPoint(outgoing)) }
            guide.lineWidth = 1
            guide.stroke()
            for point in [node.incoming, node.outgoing].compactMap({ $0 }) {
                let center = viewPoint(point)
                let handle = NSBezierPath(ovalIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
                NSColor.white.setFill(); handle.fill(); handle.stroke()
            }
            let square = NSBezierPath(roundedRect: CGRect(x: anchor.x - 4, y: anchor.y - 4, width: 8, height: 8), xRadius: 1, yRadius: 1)
            NSColor.systemBlue.setFill(); square.fill()
        }
    }

    private static let lightTransparencyBackground = transparencyBackground(base: 0.96, alternate: 0.90)
    private static let darkTransparencyBackground = transparencyBackground(base: 0.18, alternate: 0.23)

    private static func transparencyBackground(base: CGFloat, alternate: CGFloat) -> NSColor {
        let tile: CGFloat = 12
        let image = NSImage(size: CGSize(width: tile * 2, height: tile * 2), flipped: false) { rect in
            NSColor(white: base, alpha: 1).setFill()
            rect.fill()
            NSColor(white: alternate, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: tile, height: tile).fill()
            CGRect(x: tile, y: tile, width: tile, height: tile).fill()
            return true
        }
        return NSColor(patternImage: image)
    }

    private func drawTransparencyBackground(in rect: CGRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? Self.darkTransparencyBackground : Self.lightTransparencyBackground).setFill()
        rect.fill()
    }

    private func render(in context: CGContext, includeDraft: Bool) {
        let fullRect = CGRect(origin: .zero, size: imageSize)
        context.draw(image, in: fullRect)
        drawMagnifiers(in: context, fullRect: fullRect, includeDraft: includeDraft)
        for (index, item) in annotations.enumerated() {
            if includeDraft, activeTextField != nil, editingTextIndex == index {
                switch item.shape {
                case .text, .styledText: continue
                case .translation(let lines):
                    draw(.translation(lines.enumerated().compactMap {
                        $0.offset == editingTranslationLine ? nil : $0.element
                    }), in: context, fullRect: fullRect)
                    continue
                default: break
                }
            }
            draw(item, in: context, fullRect: fullRect)
        }
        if includeDraft, activeTextField != nil, let textLocation {
            if shouldShowTextPlaceholder {
                ScreenshotTextRendering.draw(textPlaceholder, at: textLocation, size: textFontSize,
                    style: .plain,
                    fontOverride: editingLegacyText ? ScreenshotTextRendering.legacyFont(size: textFontSize) : nil,
                    // The screenshot may be light while the app is in dark
                    // mode (or vice versa). A semantic placeholder color can
                    // become white-on-white; keep the hint a neutral grey.
                    foregroundOverride: NSColor(white: 0.5, alpha: 0.65), in: context)
            } else {
                let foreground = editingColor?.color ?? editingTextStyle.foreground
                ScreenshotTextRendering.drawBackground(ScreenshotTextRendering.bounds(at: textLocation,
                    text: editingText, size: textFontSize), size: textFontSize,
                    style: editingTextStyle, foreground: foreground, in: context)
                // During composition the system owns the marked text and its
                // underline. Draw the backing outline only for committed input.
                if editingTextStyle == .outlinedShadow, activeTextEditor?.hasMarkedText() != true {
                    ScreenshotTextRendering.drawOutline(editingText, at: textLocation, size: textFontSize,
                        foreground: foreground, outlineWidth: editingOutlineWidth, in: context)
                }
            }
        }
        if includeDraft, penNodes.count > 1 {
            draw(ScreenshotAnnotation.pen(penNodes, width: penWidth, closed: false).colored(penColor),
                 in: context, fullRect: fullRect)
        }
        if includeDraft, let start = dragStart, let rawEnd = dragEnd {
            let end = resolvedShapeEnd(from: start, rawEnd: rawEnd)
            let rect = resolvedShapeRect(from: start, rawEnd: rawEnd)
            func drawDraft(_ item: ScreenshotAnnotation) {
                draw(item.colored(drawingColor), in: context, fullRect: fullRect)
            }
            if tool == .sticker, let asset = pendingSticker {
                draw(.sticker(stickerRect(from: start, to: rawEnd, asset: asset), asset), in: context, fullRect: fullRect)
            }
            if tool == .arrow, let arrow = arrowAnnotation(from: start, to: end) { drawDraft(arrow) }
            if tool == .mosaic { drawDraft(.obscure(rect, mode: obscureMode, strength: obscureStrength)) }
            if tool == .rectangle || tool == .discard {
                drawDraft(boxAnnotation(in: rect))
            }
            if tool == .highlighter {
                drawDraft(.highlighter(highlighterPath(from: start, to: end),
                                       highlighterWidth, opacity: highlighterOpacity))
            }
            if tool == .brush {
                let points = dragModifiers.contains(.shift) ? [start, rawEnd] : brushPoints
                drawDraft(.brush(points, brushWidth))
            }
            if tool == .ellipse {
                drawDraft(.styledEllipse(rect, style: ellipseStyle, width: ellipseLineWidth))
            }
        }
        var spotlights = annotations.compactMap { item -> CGRect? in
            guard case .spotlight(let rect) = item.shape else { return nil }
            return rect
        }
        if includeDraft, tool == .spotlight, let start = dragStart, let end = dragEnd {
            spotlights.append(resolvedShapeRect(from: start, rawEnd: end))
        }
        let holes = spotlights.map { fullRect.intersection($0) }
            .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        if !holes.isEmpty {
            context.saveGState()
            for hole in holes {
                context.addRect(fullRect)
                context.addRect(hole)
                context.clip(using: .evenOdd)
            }
            context.setBlendMode(.sourceAtop)
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.fill(fullRect)
            context.restoreGState()
        }
    }

    private func drawMagnifiers(in context: CGContext, fullRect: CGRect, includeDraft: Bool) {
        var lenses = annotations.filter { $0.magnifierGeometry != nil }
        if includeDraft, tool == .magnifier, let start = dragStart, let end = dragEnd,
           let lens = magnifier(from: start, to: end) {
            lenses.append(lens)
        }
        guard !lenses.isEmpty else { return }

        // Draw lenses beneath other marks. Also apply redactions at their
        // magnified coordinates so a lens cannot bring masked pixels back.
        var redactions = annotations.filter {
            switch $0.shape {
            case .mosaic, .obscure: return true
            default: return false
            }
        }
        if includeDraft, tool == .mosaic, let start = dragStart, let end = dragEnd {
            redactions.append(.obscure(resolvedShapeRect(from: start, rawEnd: end),
                                      mode: obscureMode, strength: obscureStrength))
        }
        for lens in lenses {
            guard let geometry = lens.magnifierGeometry,
                  geometry.rect.width > 0, geometry.rect.height > 0 else { continue }
            let circle = geometry.rect
            let center = CGPoint(x: circle.midX, y: circle.midY)
            let shortSide = min(circle.width, circle.height)
            let rim = min(shortSide * 0.16, max(1.2, min(12, shortSide * 0.07)))
            let inner = circle.insetBy(dx: rim, dy: rim)
            let outerPath = geometry.style.path(in: circle)
            let innerPath = geometry.style.path(in: inner,
                cornerRadius: geometry.style.cornerRadius(in: circle) - rim)
            let bezel = CGMutablePath()
            bezel.addPath(outerPath)
            bezel.addPath(innerPath)
            func drawContent(magnification: CGFloat) {
                context.saveGState()
                context.translateBy(x: center.x, y: center.y)
                context.scaleBy(x: magnification, y: magnification)
                context.translateBy(x: -center.x, y: -center.y)
                context.setBlendMode(.copy)
                context.draw(image, in: fullRect)
                for mask in redactions { draw(mask, in: context, fullRect: fullRect) }
                context.restoreGState()
            }
            context.saveGState()
            context.clip(to: fullRect)
            context.saveGState()
            context.addPath(outerPath)
            context.clip()
            drawContent(magnification: geometry.magnification)
            context.restoreGState()

            // Refract the narrow glass edge separately from the clear lens.
            // Redactions follow the same transform so the rim stays masked.
            context.saveGState()
            context.addPath(bezel)
            context.clip(using: .evenOdd)
            drawContent(magnification: geometry.magnification * 0.97)
            context.restoreGState()
            Self.drawGlassMagnifierRim(in: context, rect: circle, inner: inner,
                                      bezel: bezel, width: rim, style: geometry.style)
            context.restoreGState()
        }
    }

    private static func drawGlassMagnifierRim(in context: CGContext, rect: CGRect,
                                               inner: CGRect, bezel: CGPath, width: CGFloat,
                                               style: ScreenshotMagnifierStyle) {
        func neutral(_ value: CGFloat, _ alpha: CGFloat) -> CGColor {
            CGColor(srgbRed: value, green: value, blue: value, alpha: alpha)
        }
        context.saveGState()
        context.setBlendMode(.normal)
        context.setShadow(offset: CGSize(width: 0, height: -width * 0.45),
                          blur: width * 0.95, color: neutral(0, 0.18))
        context.addPath(bezel)
        context.setFillColor(neutral(0.85, 0.12))
        context.drawPath(using: .eoFill)
        context.restoreGState()

        context.saveGState()
        context.setBlendMode(.normal)
        context.addPath(bezel)
        context.clip(using: .evenOdd)
        let colors = [neutral(1, 0.86), neutral(0.96, 0.22),
                      CGColor(srgbRed: 0.45, green: 0.52, blue: 0.61, alpha: 0.18),
                      neutral(1, 0.30), neutral(1, 0.76)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray, locations: [0, 0.28, 0.55, 0.80, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        func reflection(from start: CGFloat, to end: CGFloat, alpha: CGFloat, thickness: CGFloat) {
            let area = rect.insetBy(dx: width * 0.48, dy: width * 0.48)
            let arc = CGMutablePath()
            if style == .ellipse {
                arc.addArc(center: .zero, radius: 1, startAngle: start, endAngle: end, clockwise: false)
                var transform = CGAffineTransform(translationX: area.midX, y: area.midY)
                    .scaledBy(x: area.width / 2, y: area.height / 2)
                guard let path = arc.copy(using: &transform) else { return }
                context.addPath(path)
            } else {
                let radius = max(0, style.cornerRadius(in: rect) - width * 0.48)
                let top = start < .pi
                let y = top ? area.maxY : area.minY
                let sideY = top ? y - radius : y + radius
                arc.move(to: CGPoint(x: area.minX, y: sideY))
                arc.addQuadCurve(to: CGPoint(x: area.minX + radius, y: y),
                                 control: CGPoint(x: area.minX, y: y))
                arc.addLine(to: CGPoint(x: area.maxX - radius, y: y))
                arc.addQuadCurve(to: CGPoint(x: area.maxX, y: sideY),
                                 control: CGPoint(x: area.maxX, y: y))
                context.addPath(arc)
            }
            context.setStrokeColor(neutral(1, alpha))
            context.setLineWidth(width * thickness)
            context.setLineCap(.round)
            context.strokePath()
        }
        reflection(from: .pi * 0.18, to: .pi * 0.82, alpha: 0.82, thickness: 0.25)
        reflection(from: .pi * 1.16, to: .pi * 1.74, alpha: 0.35, thickness: 0.15)
        context.restoreGState()

        context.saveGState()
        let edge = min(width * 0.35, max(0.45, width * 0.14))
        context.setLineWidth(edge)
        context.setStrokeColor(neutral(0, 0.22))
        context.addPath(style.path(in: rect.insetBy(dx: edge / 2, dy: edge / 2),
            cornerRadius: style.cornerRadius(in: rect) - edge / 2))
        context.strokePath()
        context.setStrokeColor(neutral(0, 0.15))
        context.addPath(style.path(in: inner,
            cornerRadius: style.cornerRadius(in: rect) - width))
        context.strokePath()
        context.restoreGState()
    }

    private func draw(_ item: ScreenshotAnnotation, in context: CGContext, fullRect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        let selectedColor = item.color?.color
        let ink = selectedColor ?? .systemRed
        switch item.shape {
        case .pen(let nodes, let width, let closed):
            context.addPath(ScreenshotPenGeometry.path(nodes, closed: closed))
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        case .sticker(let rect, let asset):
            let key = asset.id as NSUUID
            var source = stickerImages.object(forKey: key)
            if source == nil, let data = CGImageSourceCreateWithData(asset.pngData as CFData, nil) {
                source = CGImageSourceCreateImageAtIndex(data, 0, nil)
                if let source { stickerImages.setObject(source, forKey: key, cost: source.bytesPerRow * source.height) }
            }
            if let source { context.interpolationQuality = .high; context.draw(source, in: rect) }
        case .colored: return
        case .arrowBox(let box): box.draw(ink: ink, in: context)
        case .arrow(let start, let end, let style, let width):
            ScreenshotArrowGeometry.draw(from: start, to: end, style: style,
                                         shaftWidth: width, ink: ink, in: context)
        case .sizedArrow(let start, let end, let style, let width, let scale):
            ScreenshotArrowGeometry.draw(from: start, to: end, style: style, shaftWidth: width,
                                         thicknessScale: scale, ink: ink, in: context)
        case .bezierArrow(let start, let control, let end, let width):
            let scaledWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
                from: start, to: end, minimumWidth: width
            )
            ScreenshotAnnotationShadow.apply(width: scaledWidth, in: context)
            context.setFillColor(ink.cgColor)
            context.addPath(ScreenshotBezierArrowGeometry.path(
                from: start, control: control, to: end, minimumWidth: width
            ))
            context.fillPath()
            let ring = ScreenshotBezierArrowGeometry.tailRing(
                from: start, to: end, minimumWidth: width
            )
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(ring.strokeWidth)
            context.strokeEllipse(in: ring.rect)
        case .sizedBezierArrow(let start, let control, let end, let width, let scale):
            let scaledWidth = ScreenshotArrowGeometry.effectiveShaftWidth(
                from: start, to: end, minimumWidth: width
            ) * scale
            ScreenshotAnnotationShadow.apply(width: scaledWidth, in: context)
            context.setFillColor(ink.cgColor)
            context.addPath(ScreenshotBezierArrowGeometry.path(
                from: start, control: control, to: end, minimumWidth: width,
                thicknessScale: scale
            ))
            context.fillPath()
            let ring = ScreenshotBezierArrowGeometry.tailRing(
                from: start, to: end, minimumWidth: width, thicknessScale: scale
            )
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(ring.strokeWidth)
            context.strokeEllipse(in: ring.rect)
        case .text(let point, let string, let fontSize):
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String):
                    CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil),
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String):
                    ink.cgColor
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: string, attributes: attributes)
            )
            context.saveGState()
            context.textPosition = point
            CTLineDraw(line, context)
            context.restoreGState()
        case .styledText(let point, let text, let size, let style, let outlineWidth):
            ScreenshotTextRendering.draw(text, at: point, size: size, style: style,
                                         foregroundOverride: selectedColor, outlineWidth: outlineWidth, in: context)
        case .spotlight, .magnifier, .ellipticalMagnifier, .rectangularMagnifier: break // Separate image-effect passes.
        case .mosaic(let rect):
            drawObscured(rect, mode: .mosaic, strength: 3, in: context, fullRect: fullRect)
        case .obscure(let rect, let mode, let strength):
            drawObscured(rect, mode: mode, strength: strength, in: context, fullRect: fullRect)
        case .rectangle(let rect):
            ScreenshotAnnotationShadow.apply(width: legacyShapeLineWidth, in: context)
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(legacyShapeLineWidth)
            context.stroke(rect)
        case .filledRectangle(let rect):
            ScreenshotAnnotationShadow.apply(width: legacyShapeLineWidth, in: context)
            context.setFillColor(ink.cgColor)
            context.fill(rect)
        case .styledRectangle(let rect, let style, let width):
            let rect = rect.standardized
            let radius = style.isRounded ? min(max(6, min(imageSize.width, imageSize.height) * 0.04),
                                               rect.width * 0.22, rect.height * 0.22) : 0
            style.draw(in: rect, radius: radius, width: width, ink: ink, context: context)
        case .styledRectangleWithRadius(let rect, let style, let width, let savedRadius):
            style.draw(in: rect.standardized, radius: savedRadius, width: width, ink: ink, context: context)
        case .number(let point, let number, let radius, let borderWidth):
            let contrast: NSColor = item.color == .white ? .black : .white
            let circle = CGRect(x: point.x - radius, y: point.y - radius,
                                width: radius * 2, height: radius * 2)
            context.setFillColor(ink.cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(contrast.cgColor)
            context.setLineWidth(borderWidth.map { min($0, radius / 2) } ?? max(1, radius / 10))
            context.strokeEllipse(in: circle)
            let digits = String(number)
            let fontSize = radius * (digits.count > 2 ? 0.8 : digits.count > 1 ? 1.0 : 1.2)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: digits, attributes: [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String):
                    CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil),
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String):
                    contrast.cgColor
            ]))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
            CTLineDraw(line, context)
        case .highlighter(let points, let width, let opacity):
            guard let first = points.first, points.count > 1 else { return }
            context.setBlendMode(item.color == .white ? .normal : .multiply)
            let highlight = selectedColor ?? NSColor(srgbRed: 1, green: 0.86, blue: 0.05, alpha: 1)
            context.setStrokeColor(highlight.withAlphaComponent(CGFloat(min(100, max(10, opacity ?? 35))) / 100).cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        case .brush(let points, let width):
            guard let first = points.first else { return }
            context.setStrokeColor(ink.cgColor)
            context.setFillColor(ink.cgColor)
            if points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x - width / 2,
                                               y: first.y - width / 2,
                                               width: width, height: width))
            } else {
                context.setLineWidth(width)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: first)
                for point in points.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            }
        case .ellipse(let rect):
            ScreenshotEllipseStyle.outline.draw(in: rect, width: legacyShapeLineWidth, ink: ink,
                                                context: context)
        case .styledEllipse(let rect, let style, let width):
            style.draw(in: rect.standardized, width: width, ink: ink, context: context)
        case .translation(let lines):
            for line in lines { drawTranslation(line, in: context, fullRect: fullRect) }
        }
    }

    private func drawTranslation(_ line: ScreenshotTranslatedLine,
                                 in context: CGContext, fullRect: CGRect) {
        // Vision uses an upper-left origin; Core Graphics renders bottom-up.
        let source = line.sourceRect
        let rect = CGRect(x: source.minX,
                          y: fullRect.height - source.maxY,
                          width: source.width, height: source.height)
            .intersection(fullRect)
        guard rect.width >= 4, rect.height >= 4, !line.text.isEmpty else { return }
        if let fontSize = line.fontSize {
            ScreenshotTranslationLayout.draw(line, size: fontSize, rect: rect, in: context)
            return
        }
        let padding = max(2, min(6, rect.height * 0.12))
        let availableWidth = max(1, rect.width - padding * 2)
        let preferredSize = max(8, min(72, rect.height * 0.92))
        let preferredFont = CTFontCreateWithName("HelveticaNeue-Medium" as CFString,
                                                 preferredSize, nil)
        let preferredText = NSAttributedString(string: line.text, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): preferredFont
        ])
        let preferredLine = CTLineCreateWithAttributedString(preferredText)
        let preferredWidth = CGFloat(CTLineGetTypographicBounds(preferredLine, nil, nil, nil))
        let fontSize = max(5, min(preferredSize,
                                  preferredSize * availableWidth / max(1, preferredWidth)))
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: line.text, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String):
                NSColor.black.cgColor
        ])
        let translatedLine = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(translatedLine, &ascent, &descent, nil)
        context.saveGState()
        context.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        context.fill(rect.insetBy(dx: -padding, dy: -max(1, padding / 2)).intersection(fullRect))
        context.textPosition = CGPoint(x: rect.minX + padding,
                                       y: rect.midY - (ascent - descent) / 2)
        CTLineDraw(translatedLine, context)
        context.restoreGState()
    }

    func renderedImage() throws -> CGImage {
        commitText()
        finishPen()
        if annotations.isEmpty { return image }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MacScreenshotError.noImage }
        render(in: context, includeDraft: false)
        guard let result = context.makeImage() else { throw MacScreenshotError.noImage }
        return result
    }

    func export(maximumBytes: Int) throws -> MacScreenshotImage {
        try MacScreenshotCapture.encode(renderedImage(), maximumBytes: maximumBytes)
    }

    private func drawObscured(_ rect: CGRect, mode: ScreenshotObscureMode, strength: Int,
                              in context: CGContext, fullRect: CGRect) {
        let area = rect.standardized.intersection(fullRect)
        guard !area.isEmpty, !area.isNull else { return }
        let level = min(5, max(1, strength))
        let key = NSNumber(value: mode.rawValue * 10 + level)
        let effect: CGImage?
        if let cached = obscuredImages.object(forKey: key) {
            effect = cached
        } else {
            if mode == .blur {
                let source = CIImage(cgImage: image)
                let blurred = source.clampedToExtent().applyingGaussianBlur(
                    sigma: Double([4, 8, 14, 22, 34][level - 1]))
                effect = blurContext.createCGImage(blurred, from: source.extent)
            } else {
                effect = Self.makeMosaicImage(from: image, tile: [6, 11, 18, 28, 44][level - 1])
            }
            if let effect {
                obscuredImages.setObject(effect, forKey: key, cost: effect.bytesPerRow * effect.height)
            }
        }
        context.clip(to: area)
        if let effect {
            if mode == .mosaic { context.interpolationQuality = .none }
            context.setBlendMode(.copy)
            context.draw(effect, in: fullRect)
        } else {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(area)
        }
    }

    private static func makeMosaicImage(from image: CGImage, tile: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: max(1, image.width / tile),
            height: max(1, image.height / tile),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: context.width, height: context.height))
        return context.makeImage()
    }
}

/// Zooms the clip view around the pointer while the canvas keeps its local
/// coordinate system. The toolbar and the exported image are independent.
@MainActor
private final class ScreenshotAnnotationScrollView: NSScrollView {
    private let canvas: ScreenshotAnnotationCanvas
    private var fittedViewport = CGSize.zero
    private var backgroundMagnifyMonitor: Any?

    init(canvas: ScreenshotAnnotationCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        let clip = CenteringClipView()
        clip.showsCheckerboard = false
        clip.drawsBackground = false
        contentView = clip
        documentView = canvas
        drawsBackground = false
        borderType = .noBorder
        scrollerStyle = .overlay
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.25
        maxMagnification = 8
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let backgroundMagnifyMonitor { NSEvent.removeMonitor(backgroundMagnifyMonitor) }
    }

    override func layout() {
        super.layout()
        fitIfNeeded()
    }

    private func fitIfNeeded() {
        let viewport = contentView.frame.size
        guard magnification <= 1, viewport != fittedViewport,
              viewport.width > 0, viewport.height > 0 else { return }
        fittedViewport = viewport
        canvas.fitEditor(to: viewport)
        // A very long image still needs to reach a readable pixel scale.
        maxMagnification = max(8, canvas.pointsToImage)
        let centered = contentView.constrainBoundsRect(contentView.bounds)
        contentView.scroll(to: centered.origin)
        reflectScrolledClipView(contentView)
    }

    func refitImage() {
        magnification = 1
        fittedViewport = .zero
        fitIfNeeded()
    }

    override func magnify(with event: NSEvent) {
        zoom(by: event.magnification, at: event.locationInWindow)
    }

    func zoom(by delta: CGFloat, at windowPoint: CGPoint) {
        let local = convert(windowPoint, from: nil)
        guard bounds.contains(local), delta.isFinite else { return }
        let point = contentView.convert(windowPoint, from: nil)
        let factor = min(2, max(0.5, 1 + delta))
        let next = min(maxMagnification, max(minMagnification, magnification * factor))
        guard next != magnification else { return }
        setMagnification(next, centeredAt: point)
        fitIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let backgroundMagnifyMonitor {
            NSEvent.removeMonitor(backgroundMagnifyMonitor)
            self.backgroundMagnifyMonitor = nil
        }
        guard window?.styleMask.contains(.nonactivatingPanel) == true else { return }
        // On a full-screen auxiliary panel AppKit can send the gesture to
        // the frontmost app. Handle that route only when our panel is hit.
        backgroundMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) {
            [weak self] event in
            let delta = event.magnification
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isVisible,
                      window.isOnActiveSpace, window.attachedSheet == nil else { return }
                let cursor = NSEvent.mouseLocation
                guard NSWindow.windowNumber(at: cursor, belowWindowWithWindowNumber: 0)
                        == window.windowNumber else { return }
                self.zoom(by: delta, at: window.convertPoint(fromScreen: cursor))
            }
        }
    }
}

private final class ScreenshotAnnotationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class ScreenshotAnnotationOverlayRoot: NSView {
    var onOutsideClick: (() -> Void)?
    var selectionFrame = CGRect.zero {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var frozenImage: NSImage? { didSet { needsDisplay = true } }
    weak var selectionCanvas: ScreenshotAnnotationCanvas?
    weak var toolbar: NSView?

    override func resetCursorRects() {
        super.resetCursorRects()
        let selectionRects = selectionCanvas?.selectionResizeCursorRects ?? []
        let curveRects = selectionCanvas?.bezierControlCursorRects ?? []
        for (rect, cursor) in selectionRects + curveRects {
            let visibleRect = rect.intersection(bounds)
            if !visibleRect.isNull && !visibleRect.isEmpty {
                addCursorRect(visibleRect, cursor: cursor)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit !== self { return hit }
        // A disabled tool segment does not accept mouse events. Keep clicks
        // anywhere in the toolbar from falling through to outside-click cancel.
        if let toolbar, toolbar.frame.contains(point) { return toolbar }
        // Handles straddle the screenshot border. Route their outer half to
        // the canvas instead of treating the click as a cancellation.
        if selectionCanvas != nil,
           selectionFrame.insetBy(dx: -ScreenshotAnnotationCanvas.handleHitRadius,
                                  dy: -ScreenshotAnnotationCanvas.handleHitRadius).contains(point) {
            return selectionCanvas
        }
        return self
    }

    override func draw(_ dirtyRect: NSRect) {
        frozenImage?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSColor.black.withAlphaComponent(0.38).setFill()
        let mask = NSBezierPath(rect: bounds)
        if !selectionFrame.isEmpty {
            mask.appendRect(selectionFrame)
            mask.windingRule = .evenOdd
        }
        mask.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toolbar?.frame.contains(point) == true { return }
        guard !selectionFrame.insetBy(dx: -24, dy: -24).contains(point) else { return }
        onOutsideClick?()
    }
}

/// A single measured row. Width constraints and arranged controls provide a
/// stable natural size even before AppKit's first stack-view layout pass.
/// A bounds transform keeps every control visible when the window is narrow.
private final class ScreenshotAnnotationToolbar: NSView {
    private final class ShadowView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            clipsToBounds = false
            layer?.masksToBounds = false
            updateAppearance()
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateAppearance()
        }

        private func updateAppearance() {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = dark ? 0.28 : 0.12
            layer?.shadowRadius = 10
            layer?.shadowOffset = CGSize(width: 0, height: -3)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
            CATransaction.commit()
        }
    }

    private final class ReadabilityPlate: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor.windowBackgroundColor
            let tint = base.blended(withFraction: dark ? 0.025 : 0.05, of: dark ? .white : .black) ?? base
            tint.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    private final class EdgeHighlight: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let lineWidth: CGFloat = increasedContrast ? 1 : 0.5
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                       xRadius: 12 - lineWidth / 2, yRadius: 12 - lineWidth / 2)
            NSColor.labelColor.withAlphaComponent(increasedContrast ? 0.35 : (dark ? 0.18 : 0.12)).setStroke()
            outline.lineWidth = lineWidth
            outline.stroke()

            let highlight = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25),
                                         xRadius: 10.75, yRadius: 10.75)
            NSColor.white.withAlphaComponent(dark ? 0.10 : 0.50).setStroke()
            highlight.lineWidth = 0.5
            highlight.stroke()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let items: [NSView]
    var onHeightChanged: ((CGFloat) -> Void)?
    private let material: NSView
    private let materialContent: NSView
    private let surfaceShadow = ShadowView()
    private let readabilityPlate = ReadabilityPlate()
    private let edgeHighlight = EdgeHighlight()
    private let content = NSView()
    private let padding: CGFloat = 10
    private let gap: CGFloat = 2
    private let rowHeight: CGFloat = 34

    init(items: [NSView], useNativeGlass: Bool = true) {
        self.items = items
        let host = NSView()
        materialContent = host
        if #available(macOS 26.0, *), useNativeGlass {
            let effect = NSGlassEffectView()
            effect.style = .clear
            effect.cornerRadius = 12
            effect.contentView = host
            material = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            effect.addSubview(host)
            material = effect
        }
        super.init(frame: .zero)
        clipsToBounds = false
        surfaceShadow.identifier = NSUserInterfaceItemIdentifier("annotation-toolbar.shadow")
        material.identifier = NSUserInterfaceItemIdentifier("annotation-toolbar.material")
        addSubview(surfaceShadow)
        addSubview(material)
        addSubview(edgeHighlight)
        host.autoresizingMask = [.width, .height]
        readabilityPlate.identifier = NSUserInterfaceItemIdentifier("annotation-toolbar.readability")
        host.addSubview(readabilityPlate)
        host.addSubview(content)
        content.autoresizesSubviews = false
        for item in items {
            item.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(item)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        readabilityPlate.needsDisplay = true
        edgeHighlight.needsDisplay = true
    }

    private func naturalSize(of view: NSView) -> CGSize {
        if let stack = view as? NSStackView {
            let sizes = stack.arrangedSubviews.map { naturalSize(of: $0) }
            let spacing = CGFloat(max(0, sizes.count - 1)) * stack.spacing
            let inset = stack.edgeInsets
            if stack.orientation == .horizontal {
                return CGSize(width: sizes.reduce(0) { $0 + $1.width } + spacing + inset.left + inset.right,
                              height: (sizes.map(\.height).max() ?? 0) + inset.top + inset.bottom)
            }
            return CGSize(width: (sizes.map(\.width).max() ?? 0) + inset.left + inset.right,
                          height: sizes.reduce(0) { $0 + $1.height } + spacing + inset.top + inset.bottom)
        }
        func fixed(_ attribute: NSLayoutConstraint.Attribute) -> CGFloat? {
            view.constraints.first {
                $0.isActive && ($0.firstItem as? NSView) === view && $0.firstAttribute == attribute
                    && $0.secondItem == nil && $0.relation == .equal
            }?.constant
        }
        let intrinsic = view.intrinsicContentSize
        return CGSize(width: fixed(.width) ?? max(0, intrinsic.width),
                      height: fixed(.height) ?? max(0, intrinsic.height))
    }

    private var sizes: [CGSize] { items.map { naturalSize(of: $0) } }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        let natural = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, items.count - 1)) * gap + padding * 2
        return CGSize(width: ceil(max(1, min(maxWidth, natural))), height: rowHeight + 20)
    }

    override func layout() {
        super.layout()
        let sizes = sizes
        let natural = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, items.count - 1)) * gap
        guard natural > 0 else { return }
        let scale = min(1, max(1, bounds.width - padding * 2) / natural)
        let visibleSize = CGSize(width: natural * scale, height: rowHeight * scale)
        let materialWidth = min(bounds.width, natural + padding * 2)
        material.frame = CGRect(x: (bounds.width - materialWidth) / 2, y: 0,
                                width: materialWidth, height: bounds.height)
        edgeHighlight.frame = material.frame
        // The editor can give this view a full-window slot. Only the rounded
        // glass body casts a shadow; controls and transparent margins do not.
        surfaceShadow.frame = material.frame
        surfaceShadow.needsLayout = true
        materialContent.frame = material.bounds
        readabilityPlate.frame = materialContent.bounds.insetBy(dx: 3, dy: 3)
        content.frame = CGRect(x: (materialContent.bounds.width - visibleSize.width) / 2,
                               y: (materialContent.bounds.height - visibleSize.height) / 2,
                               width: visibleSize.width, height: visibleSize.height)
        content.bounds = CGRect(x: 0, y: 0, width: natural, height: rowHeight)
        var x: CGFloat = 0
        for (index, item) in items.enumerated() {
            let size = sizes[index]
            item.frame = CGRect(x: x, y: (rowHeight - size.height) / 2,
                                width: size.width, height: size.height)
            x += size.width + gap
        }
        onHeightChanged?(rowHeight + 20)
    }
}

/// All selectable rows lay out their preview and text on one centreline.
/// Native submenu parents keep AppKit's built-in opening/navigation behaviour.
private final class ScreenshotToolbarMenu: NSMenu {
    private var pendingSelection: (NSMenuItem, ScreenshotToolbarMenuCommand)?

    func queue(_ item: NSMenuItem, command: ScreenshotToolbarMenuCommand) {
        guard item.isEnabled else { return }
        var root: NSMenu = self
        while let parent = root.supermenu { root = parent }
        guard let root = root as? ScreenshotToolbarMenu else { return }
        root.pendingSelection = (item, command)
        root.cancelTracking()
    }

    func performPendingSelection() {
        let selection = pendingSelection
        pendingSelection = nil
        guard let (item, command) = selection, item.isEnabled else { return }
        command.perform(item)
    }
}

private final class ScreenshotToolbarMenuCommand: NSObject {
    private weak var target: AnyObject?
    private let action: Selector

    init(target: AnyObject?, action: Selector) {
        self.target = target
        self.action = action
    }

    @objc func choose(_ item: NSMenuItem) {
        (item.menu as? ScreenshotToolbarMenu)?.queue(item, command: self)
    }

    func perform(_ item: NSMenuItem) {
        NSApp.sendAction(action, to: target, from: item)
    }
}

private enum ScreenshotToolbarMenuItem {
    @MainActor private static let trackingDelegate = ScreenshotToolbarMenuDelegate()

    @MainActor static func menu(_ title: String) -> ScreenshotToolbarMenu {
        let menu = ScreenshotToolbarMenu(title: title)
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.delegate = trackingDelegate
        return menu
    }

    @MainActor static func make(_ title: String, preview: NSImage, selected: Bool = false,
                               previewSize: CGSize = CGSize(width: 44, height: 22),
                               previewOffsetX: CGFloat = 0,
                               target: AnyObject? = nil, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.attributedTitle = NSAttributedString(string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        item.toolTip = title
        item.state = .off
        if let action {
            let command = ScreenshotToolbarMenuCommand(target: target, action: action)
            item.target = command
            item.action = #selector(ScreenshotToolbarMenuCommand.choose(_:))
            item.view = ScreenshotToolbarMenuRow(item: item, preview: preview,
                selected: selected, maximumPreviewSize: previewSize,
                previewOffsetX: previewOffsetX, command: command)
        } else {
            // Preserve AppKit's submenu tracking, but use the requested
            // preview width instead of an extra horizontal image gutter.
            // A 30-point canvas gives the native row the same 36-point height
            // as custom command rows, without enlarging the actual glyph.
            let image = NSImage(size: CGSize(width: previewSize.width, height: 30), flipped: false) { rect in
                let size = preview.size
                guard size.width > 0, size.height > 0 else { return false }
                let scale = min(1, previewSize.width / size.width, previewSize.height / size.height)
                let fitted = CGSize(width: size.width * scale, height: size.height * scale)
                preview.draw(in: CGRect(x: (rect.width - fitted.width) / 2,
                                       y: (rect.height - fitted.height) / 2,
                                       width: fitted.width, height: fitted.height))
                return true
            }
            image.isTemplate = preview.isTemplate
            item.image = image
        }
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
        return item
    }

    @MainActor static func submenu(_ title: String, preview: NSImage,
                                  previewSize: CGSize = CGSize(width: 28, height: 18),
                                  choices: NSMenu) -> NSMenuItem {
        let item = make(title, preview: preview, previewSize: previewSize)
        item.submenu = choices
        return item
    }

    @MainActor static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? badge("·")
        image.size = CGSize(width: 26, height: 26)
        image.isTemplate = true
        return image
    }

    @MainActor static func badge(_ text: String) -> NSImage {
        let image = NSImage(size: CGSize(width: 80, height: 38), flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 19, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (rect.width - size.width) / 2,
                y: (rect.height - size.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

private final class ScreenshotToolbarMenuDelegate: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            (item.view as? ScreenshotToolbarMenuRow)?.refreshAppearance()
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for candidate in menu.items {
            (candidate.view as? ScreenshotToolbarMenuRow)?.isMenuHighlighted = candidate === item
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        for item in menu.items {
            (item.view as? ScreenshotToolbarMenuRow)?.resetHighlight()
        }
    }
}

private final class ScreenshotToolbarMenuRow: NSView {
    private weak var item: NSMenuItem?
    let isSelected: Bool
    private let maximumPreviewSize: CGSize
    private let previewOffsetX: CGFloat
    private let command: ScreenshotToolbarMenuCommand
    private var labelLeading: CGFloat { 12 + maximumPreviewSize.width + 8 }
    private let preview = ScreenshotToolbarIconView()
    private let label = NSTextField(labelWithString: "")
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    var isMenuHighlighted = false { didSet { refreshAppearance() } }
    var previewFrame: CGRect { preview.frame }
    var labelFrame: CGRect { label.frame }

    override var isFlipped: Bool { true }

    init(item: NSMenuItem, preview image: NSImage, selected: Bool, maximumPreviewSize: CGSize,
         previewOffsetX: CGFloat, command: ScreenshotToolbarMenuCommand) {
        self.item = item
        isSelected = selected
        self.maximumPreviewSize = maximumPreviewSize
        self.previewOffsetX = previewOffsetX
        self.command = command
        let font = NSFont.systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        let titleWidth = (item.title as NSString).size(withAttributes: [.font: font]).width
        super.init(frame: CGRect(x: 0, y: 0,
            width: max(132, min(256, ceil(titleWidth) + 12 + maximumPreviewSize.width + 8 + 12)), height: 36))
        autoresizingMask = [.width]
        preview.image = image
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityElement(false)
        label.stringValue = item.title
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        addSubview(preview)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilityValue(selected ? "已选择" : "未选择")
        toolTip = item.title
        refreshAppearance()
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let size = preview.image?.size ?? .zero
        if size.width > 0, size.height > 0 {
            let scale = min(1, maximumPreviewSize.width / size.width, maximumPreviewSize.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            preview.frame = CGRect(x: 12 + previewOffsetX + (maximumPreviewSize.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height)
        }
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: labelLeading, y: (bounds.height - height) / 2,
                             width: max(1, bounds.width - labelLeading - 12), height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; refreshAppearance() }
    override func mouseExited(with event: NSEvent) { isHovered = false; refreshAppearance() }
    override func mouseDown(with event: NSEvent) { isHovered = true; refreshAppearance() }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    func activate() {
        guard let item, item.isEnabled, let menu = item.menu else { return }
        guard menu.index(of: item) >= 0 else { return }
        command.choose(item)
    }

    override func accessibilityPerformPress() -> Bool {
        guard item?.isEnabled == true else { return false }
        activate()
        return true
    }

    func resetHighlight() {
        isHovered = false
        isMenuHighlighted = false
        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        preview.contentTintColor = .labelColor
        label.textColor = .labelColor
        alphaValue = item?.isEnabled == false ? 0.42 : 1
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let hovered = isHovered || isMenuHighlighted
        let fill: NSColor
        if isSelected {
            fill = .controlAccentColor.withAlphaComponent(hovered ? 0.23 : 0.15)
        } else {
            fill = .labelColor.withAlphaComponent(hovered ? 0.065 : 0)
        }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
}

private final class ScreenshotToolbarIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ScreenshotToolbarSplitGroup: NSStackView {
    private weak var toolButton: ScreenshotToolbarButton?
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    init(tool: ScreenshotToolbarButton, options: ScreenshotToolbarButton) {
        super.init(frame: .zero)
        toolButton = tool
        orientation = .horizontal
        alignment = .centerY
        spacing = 0
        addArrangedSubview(tool)
        addArrangedSubview(options)
        tool.splitGroup = self
        options.splitGroup = self
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        wantsLayer = true
        let selected = toolButton?.isSelectedTool == true
        let enabled = toolButton?.isEnabled == true
        layer?.cornerRadius = 8
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        let background: NSColor = selected
            ? .controlAccentColor.withAlphaComponent(hovered ? 0.32 : 0.23)
            : (hovered && enabled ? .labelColor.withAlphaComponent(0.10) : .clear)
        layer?.backgroundColor = background.cgColor
    }
}

private final class ScreenshotToolbarButton: NSButton {
    weak var splitGroup: ScreenshotToolbarSplitGroup? { didSet { refreshAppearance() } }
    var isSelectedTool = false { didSet { refreshAppearance() } }
    var isPrimaryAction = false { didSet { refreshAppearance() } }
    override var isEnabled: Bool { didSet { refreshAppearance() } }
    private let iconView = ScreenshotToolbarIconView()
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    func setIcon(_ image: NSImage, size: CGFloat, horizontalOffset: CGFloat = 0,
                 isTemplate: Bool = true) {
        image.isTemplate = isTemplate
        iconView.image = image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: size),
            iconView.heightAnchor.constraint(equalToConstant: size),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor, constant: horizontalOffset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        refreshAppearance()
    }

    func replaceIcon(_ image: NSImage) { iconView.image = image }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        wantsLayer = true
        layer?.cornerRadius = 8
        let primary = isEnabled && isPrimaryAction
        let selected = isEnabled && isSelectedTool
        let background: NSColor
        if primary {
            background = .controlAccentColor
        } else if selected {
            background = .controlAccentColor.withAlphaComponent(isHovered ? 0.32 : 0.23)
        } else {
            background = isEnabled && isHovered ? .labelColor.withAlphaComponent(0.10) : .clear
        }
        layer?.backgroundColor = splitGroup == nil ? background.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = selected && splitGroup == nil ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
        iconView.contentTintColor = primary ? .white : .labelColor
        alphaValue = isEnabled ? 1 : 0.42
        splitGroup?.refreshAppearance()
    }
}

@MainActor
final class MacScreenshotEditorController: NSObject, NSWindowDelegate, NSPopoverDelegate {
    private var window: NSWindow?
    private var inlinePanel: NSPanel?
    private var presenter: NSWindow? { inlinePanel ?? window }
    private weak var editorToolbar: NSView?
    private weak var colorPaletteButton: ScreenshotToolbarButton?
    private weak var cropButton: ScreenshotToolbarButton?
    private weak var cancelButton: NSButton?
    private var cropDisabledControls: [(NSButton, Bool)] = []
    private var shortcutsSuspendedForScreenshot = false
    private var inlineKeyMonitor: Any?
    private var inlineGlobalEscapeMonitor: Any?
    private var onStartLongScreenshot: ((MacScreenshotFrame) -> Bool)?
    private var onCloseWindow: (() -> Void)?
    private var onCancelInline: (() -> Void)?
    private var onDismissInline: (() -> Void)?
    private var canvas: ScreenshotAnnotationCanvas?
    private var toolButtons: [ScreenshotToolbarButton] = []
    private weak var advancedToolButton: ScreenshotToolbarButton?
    private weak var advancedToolOptionsButton: ScreenshotToolbarButton?
    private weak var arrowStyleButton: ScreenshotToolbarButton?
    private weak var rectangleStyleButton: ScreenshotToolbarButton?
    private weak var ellipseStyleButton: ScreenshotToolbarButton?
    private weak var textStyleButton: ScreenshotToolbarButton?
    private weak var magnifierStyleButton: ScreenshotToolbarButton?
    private var arrowStyleMenu: NSMenu?
    private var rectangleStyleMenu: NSMenu?
    private var ellipseStyleMenu: NSMenu?
    private var textStyleMenu: NSMenu?
    private var appearanceMenu: NSMenu?
    private var undoButton: NSButton?
    private var saveButton: NSButton?
    private var screenshotTextPopover: NSPopover?
    private var screenshotTextTask: Task<Void, Never>?
    private var screenshotTextRequestID: UUID?
    private var screenshotTextLoading = false
    private var translationTask: Task<Void, Never>?
    private var translationRequestID: UUID?
    private weak var ocrButton: NSButton?
    private weak var translationButton: NSButton?
    private weak var pinButton: NSButton?
    private weak var longScreenshotButton: NSButton?
    private lazy var annotationToolHotKeys: [(ScreenshotAnnotationTool, GlobalHotKey)] =
        ScreenshotAnnotationTool.allCases.filter { $0.shortcutAction != nil }.map { tool in
            (tool, GlobalHotKey(identifier: UInt32(1000 + tool.rawValue)) { [weak self] in
                guard let self, self.canvas?.isEditingText != true,
                      self.screenshotTextPopover == nil, self.presenter?.attachedSheet == nil else { return }
                self.selectTool(tool)
            })
        }
    private lazy var penFinishHotKey = GlobalHotKey(identifier: 1099) { [weak self] in self?.canvas?.finishPen() }
    private var choosingStickerFile = false
    private enum FileExportPhase { case choosingDestination, writing }
    private var fileExportPhase: FileExportPhase?
    private var isShowingSettings = false
    private var clipboardImagePicker: NSPanel?
    private var isDismissingAnnotations = false
    private lazy var screenshotOCRHotKey = GlobalHotKey(identifier: 3) { [weak self] in
        self?.triggerScreenshotOCR()
    }
    private lazy var screenshotTranslationHotKey = GlobalHotKey(identifier: 4) { [weak self] in
        self?.triggerScreenshotTranslation()
    }
    private lazy var screenshotPinHotKey = GlobalHotKey(identifier: 5) { [weak self] in
        self?.triggerScreenshotPin()
    }
    private lazy var screenshotExportHotKey = GlobalHotKey(identifier: 11) { [weak self] in
        self?.exportImageToFile()
    }
    private lazy var elementCopyHotKey = GlobalHotKey(identifier: 1100) { [weak self] in
        self?.triggerElementClipboard(paste: false)
    }
    private lazy var elementPasteHotKey = GlobalHotKey(identifier: 1101) { [weak self] in
        self?.triggerElementClipboard(paste: true)
    }
    private var translationDownloadHost: NSView?
    private var translationLanguagesTask: Task<Void, Never>?
    private var supportedTranslationLanguages: [Locale.Language] = []
    private var translationSourceOverride: Locale.Language?
    private var translationTargetOverride: Locale.Language?
    private var inlineStatusLabel: NSTextField?
    private var inlineStatusDismissTask: Task<Void, Never>?
    private var onSave: ((MacScreenshotImage, ScreenshotEditPayload?) -> Bool)?
    private var onPin: ((MacScreenshotImage, ScreenshotEditPayload?) -> Bool)?
    private var saveFailureMessage: (() -> String?)?
    private var maximumBytes = 0
    private(set) var inlineSourceFrame: CGRect?
    var inlineOverlayWindowID: CGWindowID? {
        inlinePanel.map { CGWindowID($0.windowNumber) }
    }
    private var isRefreshingInlineSelection = false
    var isPresenting: Bool { window != nil || inlinePanel != nil }
    var canStartLongScreenshot: Bool { inlinePanel != nil && onStartLongScreenshot != nil }
    var hasAnnotations: Bool { canvas?.hasChanges == true }

    /// A new screen capture has its own controller. Leave this image visible,
    /// but let the screenshot selector receive Esc, Return and tool shortcuts.
    func setScreenshotInteractionActive(_ active: Bool) {
        shortcutsSuspendedForScreenshot = active
        canvas?.isInputSuspended = active
        updateAnnotationToolHotKeys()
    }

    func open(data: Data, editableBaseData: Data? = nil,
              editableDocumentData: Data? = nil, maximumBytes: Int,
              saveFailureMessage: (() -> String?)? = nil,
              onPin: ((MacScreenshotImage, ScreenshotEditPayload?) -> Bool)? = nil,
              onSave: @escaping (MacScreenshotImage, ScreenshotEditPayload?) -> Bool) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let flattenedImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        var canvas = ScreenshotAnnotationCanvas(image: flattenedImage)
        if let editableBaseData, let editableDocumentData,
           let baseSource = CGImageSourceCreateWithData(editableBaseData as CFData, nil),
           let baseImage = CGImageSourceCreateImageAtIndex(baseSource, 0, nil) {
            let editableCanvas = ScreenshotAnnotationCanvas(image: baseImage)
            if editableCanvas.loadDocument(editableDocumentData) { canvas = editableCanvas }
        }
        return openWindow(canvas, maximumBytes: maximumBytes,
                          saveFailureMessage: saveFailureMessage, onPin: onPin, onSave: onSave)
    }

    func openLongScreenshot(image: CGImage, on screen: NSScreen, maximumBytes: Int,
                            saveFailureMessage: (() -> String?)? = nil,
                            onClose: @escaping () -> Void,
                            onSave: @escaping (MacScreenshotImage, ScreenshotEditPayload?) -> Bool) -> Bool {
        openWindow(ScreenshotAnnotationCanvas(image: image), longScreenshotScreen: screen,
                   maximumBytes: maximumBytes, saveFailureMessage: saveFailureMessage,
                   onClose: onClose, onSave: onSave)
    }

    private func openWindow(_ canvas: ScreenshotAnnotationCanvas,
                            longScreenshotScreen: NSScreen? = nil, maximumBytes: Int,
                            saveFailureMessage: (() -> String?)?, onClose: (() -> Void)? = nil,
                            onPin: ((MacScreenshotImage, ScreenshotEditPayload?) -> Bool)? = nil,
                            onSave: @escaping (MacScreenshotImage, ScreenshotEditPayload?) -> Bool) -> Bool {
        dismissInline()
        window?.close()
        self.onCloseWindow = onClose
        self.maximumBytes = maximumBytes
        self.onSave = onSave
        self.onPin = onPin
        self.saveFailureMessage = saveFailureMessage
        self.canvas = canvas
        canvas.isInputSuspended = shortcutsSuspendedForScreenshot
        restoreStylePreferences(on: canvas)

        let available = (longScreenshotScreen ?? NSScreen.main)?.visibleFrame.size
            ?? CGSize(width: 1024, height: 768)
        let initialSize = CGSize(width: min(980, available.width - 32),
                                 height: min(690, available.height - 32))
        let compactToolbar = initialSize.width < 900
        let window: NSWindow
        if let screen = longScreenshotScreen {
            window = LongScreenshotPanel(size: initialSize, on: screen)
        } else {
            window = NSWindow(contentRect: CGRect(origin: .zero, size: initialSize),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.center()
        }
        window.title = "标注图片"
        window.minSize = NSSize(width: min(initialSize.width, compactToolbar ? 720 : 900), height: 440)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        let root = NSView()
        let toolbar = makeToolbar(inline: false, compact: compactToolbar)
        let canFinishWithoutEdits = longScreenshotScreen != nil
        saveButton?.isEnabled = canFinishWithoutEdits
        root.addSubview(toolbar)
        let content = ScreenshotAnnotationScrollView(canvas: canvas)
        root.addSubview(content)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        let toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: toolbar.preferredSize(maxWidth: initialSize.width).height)
        toolbar.onHeightChanged = { [weak toolbarHeight] height in
            if toolbarHeight?.constant != height { toolbarHeight?.constant = height }
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarHeight,
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        self.window = window
        canvas.onChange = { [weak self, weak canvas] in
            guard let canvas else { return }
            self?.updateAnnotationToolHotKeys()
            self?.updatePaletteIcon()
            self?.closeScreenshotTextPopover()
            self?.cancelScreenshotTranslation()
            self?.undoButton?.isEnabled = canvas.canUndo
            self?.saveButton?.isEnabled = canFinishWithoutEdits || canvas.canUndo
        }
        canvas.onImageSizeChanged = { [weak content] in content?.refitImage() }
        canvas.onCropChanged = { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.updateCropControls()
            self.saveButton?.isEnabled = canvas.isCropping
                ? canvas.cropRect.flatMap { ScreenshotCropGeometry.pixelRect($0,
                    in: CGSize(width: canvas.image.width, height: canvas.image.height)) } != nil
                : canFinishWithoutEdits || canvas.canUndo
        }
        selectTool(restoredTool(), persist: false)
        installEditorKeyMonitor()
        loadSupportedTranslationLanguages()
        if longScreenshotScreen != nil {
            window.orderFrontRegardless()
            window.makeKey()
        } else {
            _ = NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(canvas)
        return true
    }

    func openInline(image: CGImage, sourceFrame: CGRect,
                    selectionPanel: NSPanel? = nil,
                    isWindowCapture: Bool = false,
                    frozenDisplay: MacScreenshotFrozenDisplay? = nil,
                    startAction: ScreenshotStartAction = .annotate,
                    maximumBytes: Int,
                    saveFailureMessage: (() -> String?)? = nil,
                    onSave: @escaping (MacScreenshotImage, ScreenshotEditPayload?) -> Bool,
                    onPin: @escaping (MacScreenshotImage, ScreenshotEditPayload?) -> Bool,
                    onLongScreenshot: @escaping (MacScreenshotFrame) -> Bool,
                    onCancel: @escaping () -> Void,
                    onDismiss: @escaping () -> Void) -> Bool {
        guard let screen = selectionPanel?.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(sourceFrame) })
            ?? NSScreen.main else { return false }
        let screenFrame = selectionPanel?.frame ?? screen.frame
        let visibleSelection = sourceFrame.intersection(screenFrame)
        guard visibleSelection.width >= 5, visibleSelection.height >= 5 else { return false }
        // The overlay clips the off-screen part of an isolated window bitmap.
        // Fitting the full bitmap into the intersection shifts and shrinks it.
        let selectedFrame = isWindowCapture ? sourceFrame : visibleSelection
        let toolbarSafeArea = screen.visibleFrame.intersection(screenFrame)
            .offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            .insetBy(dx: 12, dy: 12)
        window?.close()
        dismissInline()
        self.maximumBytes = maximumBytes
        self.onSave = onSave
        self.onPin = onPin
        self.saveFailureMessage = saveFailureMessage
        self.onStartLongScreenshot = onLongScreenshot
        self.onCancelInline = onCancel
        self.onDismissInline = onDismiss
        inlineSourceFrame = selectedFrame
        translationSourceOverride = nil
        translationTargetOverride = nil
        supportedTranslationLanguages = []

        let panel: NSPanel
        if let selectionPanel {
            panel = selectionPanel
        } else {
            panel = ScreenshotAnnotationOverlayPanel(
                contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        // Full-screen screenshot layers must never use a window zoom/fade,
        // including the whole-screen entry that doesn't reuse a selector.
        panel.animationBehavior = .none
        panel.worksWhenModal = true
        let root = ScreenshotAnnotationOverlayRoot(
            frame: CGRect(origin: .zero, size: screenFrame.size)
        )
        if let frozenDisplay {
            root.frozenImage = NSImage(cgImage: frozenDisplay.image,
                                       size: screenFrame.size)
        }
        root.onOutsideClick = { [weak self] in
            guard let self else { return }
            if self.screenshotTextPopover?.isShown == true {
                self.closeScreenshotTextPopover()
            } else if self.translationRequestID != nil {
                self.cancelScreenshotTranslation()
            } else {
                self.cancel()
            }
        }
        let localFrame = selectedFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        root.selectionFrame = localFrame
        let canvas = ScreenshotAnnotationCanvas(image: image, contentInset: 0)
        canvas.strokePixelsPerPoint = CGFloat(image.width) / selectedFrame.width
        canvas.frame = localFrame
        root.addSubview(canvas)
        root.selectionCanvas = canvas
        self.canvas = canvas
        restoreStylePreferences(on: canvas)
        let compactToolbar = toolbarSafeArea.width < 1024
        let toolbar = makeToolbar(inline: true, compact: compactToolbar)
        let toolbarSize = toolbar.preferredSize(maxWidth: max(240, toolbarSafeArea.width - 24))
        func toolbarFrame(for selection: CGRect) -> CGRect {
            MacScreenshotGeometry.toolbarFrame(near: selection, in: toolbarSafeArea,
                size: toolbarSize, gap: ScreenshotAnnotationCanvas.handleHitRadius + 10)
        }
        toolbar.frame = toolbarFrame(for: localFrame)
        root.addSubview(toolbar)
        root.toolbar = toolbar
        // System tooltip windows sit below screen-saver-level windows. The
        // annotation layer only needs pop-up-menu level above app windows,
        // allowing toolbar hints to appear in front instead of behind it.
        panel.level = .popUpMenu
        panel.acceptsMouseMovedEvents = true
        panel.contentView = root
        panel.becomesKeyOnlyIfNeeded = true
        inlinePanel = panel
        loadSupportedTranslationLanguages()
        canvas.onChange = { [weak self, weak canvas] in
            guard let canvas else { return }
            self?.updateAnnotationToolHotKeys()
            self?.updatePaletteIcon()
            self?.closeScreenshotTextPopover()
            self?.cancelScreenshotTranslation()
            self?.undoButton?.isEnabled = canvas.canUndo
            self?.invalidateInlineCursorRects()
        }
        canvas.onDoubleClick = { [weak self] in self?.save() }
        canvas.onSelectionChanged = { [weak self, weak root, weak canvas] next, finished, moving in
            guard let self, let root, let canvas else { return }
            self.closeScreenshotTextPopover()
            self.cancelScreenshotTranslation()
            root.selectionFrame = next
            toolbar.frame = toolbarFrame(for: next)
            self.positionInlineStatus(near: toolbar.frame, in: root.bounds)
            guard finished, !self.isRefreshingInlineSelection,
                  let panel = self.inlinePanel else { return }
            let global = next.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
            let previousSourceFrame = self.inlineSourceFrame
            if let frozenDisplay {
                do {
                    let cropped = try frozenDisplay.crop(global)
                    canvas.replaceImage(cropped.image, from: previousSourceFrame,
                                        to: cropped.frame, movingSelection: moving)
                    self.inlineSourceFrame = cropped.frame
                    let alignedLocal = cropped.frame.offsetBy(dx: -screenFrame.minX,
                                                              dy: -screenFrame.minY)
                    canvas.frame = alignedLocal
                    root.selectionFrame = alignedLocal
                    toolbar.frame = toolbarFrame(for: alignedLocal)
                    self.positionInlineStatus(near: toolbar.frame, in: root.bounds)
                } catch {
                    if let previous = self.inlineSourceFrame {
                        let priorLocal = previous.offsetBy(dx: -screenFrame.minX,
                                                           dy: -screenFrame.minY)
                        canvas.frame = priorLocal
                        root.selectionFrame = priorLocal
                    }
                    canvas.isAdjustingSelection = false
                    NSSound.beep()
                }
                return
            }
            self.isRefreshingInlineSelection = true
            self.saveButton?.isEnabled = false
            Task { @MainActor [weak self, weak canvas, weak root] in
                do {
                    let refreshed = try await MacScreenshotCapture.captureRegionExcludingSelector(
                        global, selectorWindowID: CGWindowID(panel.windowNumber)
                    )
                    guard let self, self.inlinePanel === panel, let canvas else { return }
                    canvas.replaceImage(refreshed, from: previousSourceFrame,
                                        to: global, movingSelection: moving)
                    self.inlineSourceFrame = global
                } catch {
                    guard let self, self.inlinePanel === panel, let canvas else { return }
                    if let previous = self.inlineSourceFrame {
                        let priorLocal = previous.offsetBy(dx: -screenFrame.minX,
                                                           dy: -screenFrame.minY)
                        canvas.frame = priorLocal
                        root?.selectionFrame = priorLocal
                    }
                    canvas.isAdjustingSelection = false
                    NSSound.beep()
                }
                self?.isRefreshingInlineSelection = false
                self?.saveButton?.isEnabled = true
            }
        }
        selectTool(restoredTool(), persist: false)
        // Keep the existing selection panel visible during the handoff, and
        // prepare new/hidden panels before their first orderFront as well.
        MacScreenshotPresentation.prepare(root)
        if selectionPanel == nil {
            panel.orderFrontRegardless()
        }
        registerScreenshotToolHotKeys()
        installEditorKeyMonitor()
        inlineGlobalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isShowingSettings, self.fileExportPhase != .choosingDestination,
                      let panel = self.inlinePanel,
                      panel.attachedSheet == nil else { return }
                self.handleInlineEscape()
            }
        }
        if inlineGlobalEscapeMonitor == nil {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(canvas)
        }
        if startAction != .annotate {
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self, let panel, self.inlinePanel === panel else { return }
                switch startAction {
                case .annotate: break
                case .recognizeText: self.triggerScreenshotOCR()
                case .translate: self.triggerScreenshotTranslation()
                }
            }
        }
        return true
    }

    private func loadSupportedTranslationLanguages() {
        guard #available(macOS 15.0, *) else { return }
        translationLanguagesTask?.cancel()
        translationLanguagesTask = Task { @MainActor [weak self] in
            let languages = await LanguageAvailability().supportedLanguages
            guard !Task.isCancelled, let self, self.isPresenting else { return }
            self.supportedTranslationLanguages = languages.sorted {
                self.translationLanguageName($0).localizedStandardCompare(
                    self.translationLanguageName($1)) == .orderedAscending
            }
        }
    }

    private func installEditorKeyMonitor() {
        if let inlineKeyMonitor { NSEvent.removeMonitor(inlineKeyMonitor) }
        inlineKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, !self.shortcutsSuspendedForScreenshot,
                  !self.isShowingSettings, self.fileExportPhase != .choosingDestination,
                  let panel = self.presenter, panel.attachedSheet == nil else { return event }
            if self.inlinePanel == nil, event.window !== panel,
               self.screenshotTextPopover?.isShown != true { return event }
            if event.keyCode == 53 {
                self.handleInlineEscape()
                return nil
            }
            if self.canvas?.isCropping == true {
                if [36, 76].contains(event.keyCode) {
                    if !event.isARepeat { _ = self.canvas?.applyCrop() }
                    return nil
                }
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "z" {
                    self.canvas?.cancelCrop()
                    return nil
                }
                return event
            }
            if self.screenshotTextPopover != nil { return event }
            if self.canvas?.handleElementClipboardShortcut(event) == true { return nil }
            let exportShortcut = AppController.shared.shortcut(for: .saveImageToFile)
            if exportShortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                if !event.isARepeat { self.exportImageToFile() }
                return nil
            }
            if self.canvas?.isEditingText != true, self.screenshotTextPopover == nil,
               self.canvas?.isBuildingPenPath == true, [36, 76].contains(event.keyCode) {
                self.canvas?.finishPen(); return nil
            }
            if self.handleScreenshotToolShortcut(event) { return nil }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "z",
               self.canvas?.isEditingText != true {
                if event.modifierFlags.contains(.shift) { self.canvas?.redo() }
                else { self.undo() }
                return nil
            }
            if self.canvas?.isEditingText != true {
                if event.keyCode == 51 || event.keyCode == 117 {
                    self.canvas?.deleteSelectedElement()
                    return nil
                }
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                switch event.keyCode {
                case 123: self.canvas?.nudgeSelectedElement(dx: -step, dy: 0); return nil
                case 124: self.canvas?.nudgeSelectedElement(dx: step, dy: 0); return nil
                case 125: self.canvas?.nudgeSelectedElement(dx: 0, dy: -step); return nil
                case 126: self.canvas?.nudgeSelectedElement(dx: 0, dy: step); return nil
                default: break
                }
            }
            if event.keyCode == 36, self.canvas?.isEditingText != true {
                self.save()
                return nil
            }
            return event
        }
    }

    private func makeToolbar(inline: Bool, compact: Bool = false) -> ScreenshotAnnotationToolbar {
        let tools = ScreenshotAnnotationTool.allCases
        toolButtons = tools.map { tool in
            let button = screenshotActionButton(
                tool.icon, hint: annotationToolHint(tool),
                action: #selector(toolChanged(_:)), compact: compact,
                iconOffsetX: [.rectangle, .ellipse, .arrow, .text, .mosaic, .highlighter, .magnifier].contains(tool) ? 2 : 0,
                icon: tool == .spotlight ? spotlightIcon : nil
            )
            button.tag = tool.rawValue
            return button
        }
        let undo = screenshotActionButton(
            .undo2, hint: "撤销上一项标注", action: #selector(undo), compact: compact
        )
        undo.isEnabled = false
        undoButton = undo
        let cancel = screenshotActionButton(
            .x, hint: inline ? "取消截图（Esc）" : "取消标注",
            action: #selector(cancel), compact: compact, iconSize: compact ? 14 : 16
        )
        cancelButton = cancel
        let save = screenshotActionButton(
            .copyCheck, hint: inline ? "完成并复制截图" : "保存并复制标注图片",
            action: #selector(save), compact: compact
        )
        save.isPrimaryAction = true
        save.isEnabled = inline
        if !inline { save.keyEquivalent = "\r" }
        saveButton = save
        let arrowStyles = screenshotActionButton(
            .chevronDown, hint: "选择箭头样式", action: #selector(showArrowStyleMenu(_:)),
            compact: compact, width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12
        )
        arrowStyleButton = arrowStyles
        let rectangleStyles = screenshotActionButton(
            .chevronDown, hint: "选择矩形样式", action: #selector(showRectangleStyleMenu(_:)),
            compact: compact, width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12
        )
        rectangleStyleButton = rectangleStyles
        let ellipseStyles = screenshotActionButton(
            .chevronDown, hint: "选择椭圆样式", action: #selector(showEllipseStyleMenu(_:)),
            compact: compact, width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12
        )
        ellipseStyleButton = ellipseStyles
        let textStyles = screenshotActionButton(
            .chevronDown, hint: "选择文字样式", action: #selector(showTextStyleMenu(_:)),
            compact: compact, width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12
        )
        textStyleButton = textStyles
        let magnifierStyles = screenshotActionButton(
            .chevronDown, hint: "选择放大镜形状", action: #selector(showMagnifierStyleMenu(_:)),
            compact: compact, width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12
        )
        magnifierStyleButton = magnifierStyles
        func horizontalGroup(_ views: [NSView], spacing: CGFloat) -> NSStackView {
            let group = NSStackView(views: views)
            group.orientation = .horizontal
            group.spacing = spacing
            group.alignment = .centerY
            group.distribution = .fill
            return group
        }
        func styleGroup(_ tool: ScreenshotAnnotationTool,
                        _ menuButton: ScreenshotToolbarButton) -> NSStackView {
            ScreenshotToolbarSplitGroup(tool: toolButtons[tool.rawValue], options: menuButton)
        }
        func divider() -> NSView {
            let view = NSBox()
            view.boxType = .separator
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
            view.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return view
        }
        let obscureOptions = screenshotActionButton(.chevronDown, hint: "选择遮盖方式和强度",
            action: #selector(showObscureMenu(_:)), compact: compact,
            width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12)
        let highlighterOptions = screenshotActionButton(.chevronDown, hint: "调整荧光笔不透明度",
            action: #selector(showHighlighterMenu(_:)), compact: compact,
            width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12)
        let palette = ScreenshotToolbarButton()
        palette.title = ""
        palette.isBordered = false
        palette.target = self
        palette.action = #selector(showColorMenu(_:))
        palette.toolTip = "标注颜色"
        palette.setAccessibilityLabel("标注颜色")
        palette.setIcon((canvas?.annotationColor ?? .red).toolbarColorSwatch,
                        size: 22, horizontalOffset: 2, isTemplate: false)
        colorPaletteButton = palette
        palette.widthAnchor.constraint(equalToConstant: compact ? 28 : 32).isActive = true
        palette.heightAnchor.constraint(equalToConstant: compact ? 28 : 34).isActive = true
        let colorOptions = screenshotActionButton(.chevronDown, hint: "选择标注颜色",
            action: #selector(showColorMenu(_:)), compact: compact,
            width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12)
        let advanced = screenshotActionButton(.ellipsis, hint: "高级工具",
            action: #selector(showAdvancedToolMenu(_:)), compact: compact, icon: advancedToolsIcon)
        let advancedOptions = screenshotActionButton(.chevronDown, hint: "选择高级工具",
            action: #selector(showAdvancedToolMenu(_:)), compact: compact,
            width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12)
        advancedToolButton = advanced
        advancedToolOptionsButton = advancedOptions
        let annotations: [NSView] = [
            styleGroup(.rectangle, rectangleStyles),
            styleGroup(.ellipse, ellipseStyles),
            styleGroup(.arrow, arrowStyles),
            styleGroup(.text, textStyles),
            styleGroup(.mosaic, obscureOptions),
            styleGroup(.highlighter, highlighterOptions),
            toolButtons[ScreenshotAnnotationTool.brush.rawValue],
            toolButtons[ScreenshotAnnotationTool.discard.rawValue],
            styleGroup(.magnifier, magnifierStyles),
            toolButtons[ScreenshotAnnotationTool.number.rawValue],
            ScreenshotToolbarSplitGroup(tool: advanced, options: advancedOptions),
            ScreenshotToolbarSplitGroup(tool: palette, options: colorOptions)
        ]
        updateStyleHelp()
        var controls: [NSView] = []
        if !inline {
            let crop = screenshotActionButton(.square, hint: "裁剪图片：拖动框选，回车确认，Esc 取消",
                action: #selector(toggleCrop), compact: compact,
                icon: NSImage(systemSymbolName: "crop", accessibilityDescription: "裁剪图片"))
            crop.identifier = NSUserInterfaceItemIdentifier("annotation.crop")
            cropButton = crop
            controls += [crop, divider()]
        }
        controls += annotations + [divider()]
        var finishing: [NSView] = [undo]
        do {
            let ocrShortcut = AppController.shared.shortcut(for: .recognizeImageText).displayName
            let translationShortcut = AppController.shared.shortcut(for: .translateScreenshot).displayName
            let pinShortcut = AppController.shared.shortcut(for: .togglePinImage).displayName
            let ocr = screenshotActionButton(
                .scanSearch, hint: "识别当前图片中的文字（\(ocrShortcut)）",
                action: #selector(recognizeScreenshotText(_:)), compact: compact
            )
            let translation = screenshotActionButton(
                .languages, hint: "翻译图片文字（\(translationShortcut)）：自动中英互译；再次点击恢复原文",
                action: #selector(translateScreenshotText(_:)), compact: compact, iconOffsetX: 2
            )
            let languageMenu = screenshotActionButton(
                .chevronDown, hint: "选择截图翻译的原文和译文语言",
                action: #selector(showTranslationLanguageMenu(_:)), compact: compact,
                width: compact ? 14 : 16, iconOffsetX: -5, iconSize: 12
            )
            if #unavailable(macOS 15.0) {
                translation.isEnabled = false
                languageMenu.isEnabled = false
                translation.toolTip = "图片内翻译需要 macOS 15 或更新版本"
                languageMenu.toolTip = translation.toolTip
            }
            let translationGroup = ScreenshotToolbarSplitGroup(tool: translation, options: languageMenu)
            let pin = screenshotActionButton(
                .pin, hint: onPin == nil ? "当前标注窗口不支持直接钉住，请保存后从图片卡片钉住"
                    : (inline ? "完成并钉住（\(pinShortcut)）：保存最终图片并贴在截图原位置"
                        : "保存并钉住当前图片（\(pinShortcut)）"),
                action: #selector(pinScreenshot(_:)), compact: compact
            )
            ocrButton = ocr
            translationButton = translation
            pinButton = pin
            pin.isEnabled = onPin != nil
            let longShortcut = AppController.shared.shortcut(for: .captureLongScreenshot).displayName
            let scrolling = screenshotActionButton(
                .scrollText, hint: inline ? "以当前选区开始长截图（\(longShortcut)）"
                    : "已有图片无法滚动采集，请从屏幕截图选区开始长截图",
                action: #selector(startLongScreenshot), compact: compact
            )
            longScreenshotButton = scrolling
            scrolling.isEnabled = inline && onStartLongScreenshot != nil
            controls += [horizontalGroup([ocr, translationGroup, scrolling], spacing: 2), divider()]
            finishing.append(pin)
        }
        if !inline {
            let shortcut = AppController.shared.shortcut(for: .saveImageToFile).displayName
            finishing.append(screenshotActionButton(
                .download, hint: "保存为…（\(shortcut)）",
                action: #selector(exportImageToFile), compact: compact
            ))
        }
        finishing += [cancel, save]
        controls.append(horizontalGroup(finishing, spacing: 2))
        let toolbar = ScreenshotAnnotationToolbar(items: controls)
        editorToolbar = toolbar
        return toolbar
    }

    private func providedToolbarIcon(_ symbol: LucideSymbol) -> NSImage? {
        let name: String
        switch symbol {
        case .square: name = "rectangle"
        case .circle: name = "circle"
        case .arrowUpRight: name = "arrow"
        case .type: name = "text"
        case .zoomIn: name = "zoom-in"
        case .grid3x3: name = "mosaic"
        case .highlighter: name = "marker"
        case .pencil: name = "pen"
        case .listOrdered: name = "number"
        case .scanSearch: name = "ocr"
        case .languages: name = "translate"
        case .scrollText: name = "scroll-capture"
        case .settings: name = "extra-settings"
        case .penTool, .image, .pin, .undo2, .x, .squareX, .copyCheck, .chevronDown, .ellipsis:
            name = "extra-" + symbol.rawValue
        default: return nil
        }
        return NSImage(named: "AnnotationToolbar-" + name)?.copy() as? NSImage
    }

    private func updatePaletteIcon() {
        guard let canvas else { return }
        let color = canvas.selectedColor ?? canvas.annotationColor
        colorPaletteButton?.replaceIcon(color.toolbarColorSwatch)
        colorPaletteButton?.setAccessibilityValue(color.title)
    }

    private func screenshotActionButton(
        _ symbol: LucideSymbol, hint: String, action: Selector, compact: Bool,
        width: CGFloat? = nil, iconOffsetX: CGFloat = 0, iconSize: CGFloat? = nil,
        icon: NSImage? = nil
    ) -> ScreenshotToolbarButton {
        let button = ScreenshotToolbarButton()
        let image = icon
            ?? providedToolbarIcon(symbol)
            ?? (NSImage(named: "LucideToolbar-\(symbol.rawValue)")?.copy() as? NSImage)
            ?? (NSImage(named: symbol.assetName)?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "questionmark.square",
                       accessibilityDescription: hint)
        button.title = ""
        button.imagePosition = .imageOnly
        button.isBordered = false
        if let image {
            button.setIcon(image, size: iconSize ?? (compact ? 16 : 18),
                           horizontalOffset: iconOffsetX)
        }
        button.toolTip = hint
        button.setAccessibilityLabel(hint)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: width ?? (compact ? 26 : 32)).isActive = true
        button.heightAnchor.constraint(equalToConstant: compact ? 28 : 34).isActive = true
        button.refreshAppearance()
        return button
    }

    private var spotlightIcon: NSImage {
        NSImage(size: CGSize(width: 24, height: 24), flipped: false) { _ in
            let outside = NSBezierPath(roundedRect: CGRect(x: 2.5, y: 2.5, width: 19, height: 19),
                                       xRadius: 2, yRadius: 2)
            let inside = NSBezierPath(rect: CGRect(x: 7, y: 9, width: 10, height: 6))
            let mask = outside.copy() as! NSBezierPath
            mask.append(inside)
            mask.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.42).setFill()
            mask.fill()
            NSColor.black.setStroke()
            outside.lineWidth = 2.16
            inside.lineWidth = 1.8
            outside.stroke()
            inside.stroke()
            return true
        }
    }

    private func annotationToolHint(_ tool: ScreenshotAnnotationTool) -> String {
        let key = tool.shortcutAction.map { "（\(AppController.shared.shortcut(for: $0).displayName)）" } ?? ""
        return tool.title + key + " · " + tool.hint
    }

    private func selectTool(_ tool: ScreenshotAnnotationTool, persist: Bool = true) {
        appearanceMenu?.cancelTracking()
        canvas?.cancelCrop()
        canvas?.finishPen()
        canvas?.tool = tool
        for button in toolButtons {
            button.isSelectedTool = button.tag == tool.rawValue
        }
        updateAdvancedToolButton(for: tool)
        updatePaletteIcon()
        if persist {
            UserDefaults.standard.set(tool.rawValue, forKey: ScreenshotAnnotationPreferences.lastToolKey)
        }
        invalidateInlineCursorRects()
    }

    private func annotationToolImage(_ tool: ScreenshotAnnotationTool) -> NSImage? {
        tool == .spotlight ? spotlightIcon
            : providedToolbarIcon(tool.icon) ?? (NSImage(named: tool.icon.assetName)?.copy() as? NSImage)
    }

    private var advancedToolsIcon: NSImage? {
        guard let source = providedToolbarIcon(.ellipsis) else { return nil }
        let image = NSImage(size: source.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: .pi / 2)
            source.draw(in: CGRect(x: -rect.width / 2, y: -rect.height / 2,
                                   width: rect.width, height: rect.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    private func updateAdvancedToolButton(for tool: ScreenshotAnnotationTool) {
        guard let button = advancedToolButton else { return }
        let selected = ScreenshotAnnotationTool.advancedTools.contains(tool)
        if let image = advancedToolsIcon {
            image.isTemplate = true
            button.replaceIcon(image)
        }
        button.isSelectedTool = selected
        button.toolTip = selected ? "高级工具 · " + annotationToolHint(tool) + " · 点击切换工具"
            : "高级工具"
        button.setAccessibilityLabel(button.toolTip)
        button.setAccessibilityValue(selected ? tool.title : "未选择")
        advancedToolOptionsButton?.setAccessibilityValue(selected ? tool.title : "未选择")
    }

    @objc private func showAdvancedToolMenu(_ sender: NSButton) {
        let menu = ScreenshotToolbarMenuItem.menu("高级工具")
        menu.autoenablesItems = false
        for tool in ScreenshotAnnotationTool.advancedTools {
            guard let image = annotationToolImage(tool) else { continue }
            image.isTemplate = true
            let item: NSMenuItem
            if tool == .sticker {
                item = ScreenshotToolbarMenuItem.submenu(tool.title, preview: image,
                    previewSize: CGSize(width: 20, height: 20), choices: stickerSourceMenu())
            } else {
                item = ScreenshotToolbarMenuItem.make(tool.title, preview: image,
                    selected: canvas?.tool == tool, previewSize: CGSize(width: 20, height: 20), previewOffsetX: 2, target: self,
                    action: #selector(chooseAdvancedToolMenuItem(_:)))
            }
            item.tag = tool.rawValue
            item.toolTip = annotationToolHint(tool)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if inlinePanel != nil {
            let shortcut = AppController.shared.shortcut(for: .saveImageToFile).displayName
            let export = ScreenshotToolbarMenuItem.make("保存为…（\(shortcut)）",
                preview: NSImage(named: LucideSymbol.download.assetName)
                    ?? ScreenshotToolbarMenuItem.symbol("arrow.down.to.line"),
                previewSize: CGSize(width: 20, height: 20), previewOffsetX: 2,
                target: self, action: #selector(exportImageToFile))
            export.isEnabled = canExportImage
            menu.addItem(export)
        }
        menu.addItem(ScreenshotToolbarMenuItem.make("设置",
            preview: providedToolbarIcon(.settings) ?? ScreenshotToolbarMenuItem.symbol("gearshape"),
            previewSize: CGSize(width: 20, height: 20), previewOffsetX: 2, target: self,
            action: #selector(openAnnotationSettings)))
        popUpAppearanceMenu(menu, from: sender)
    }

    @objc private func chooseAdvancedToolMenuItem(_ item: NSMenuItem) {
        chooseAdvancedTool(item.tag)
    }

    private func chooseAdvancedTool(_ tag: Int) {
        guard let tool = ScreenshotAnnotationTool(rawValue: tag),
              ScreenshotAnnotationTool.advancedTools.contains(tool) else { return }
        if tool == .sticker {
            guard isPresenting, presenter?.attachedSheet == nil,
                  let button = advancedToolButton else { return }
            showStickerMenu(button)
        } else {
            selectTool(tool)
        }
    }

    @objc private func openAnnotationSettings() {
        guard let presenter, !isShowingSettings else { return }
        closeScreenshotTextPopover()
        cancelScreenshotTranslation()
        isShowingSettings = true
        updateAnnotationToolHotKeys()
        unregisterScreenshotToolHotKeys()
        presenter.orderOut(nil)
        AppController.shared.openSettings(category: .screenshots) { [weak self, weak presenter] in
            guard let self, let presenter, self.isShowingSettings,
                  self.presenter === presenter else { return }
            self.isShowingSettings = false
            if self.inlinePanel != nil {
                self.registerScreenshotToolHotKeys()
            } else {
                _ = NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            presenter.makeKeyAndOrderFront(nil)
            presenter.makeFirstResponder(self.canvas)
        }
    }

    private func restoredTool() -> ScreenshotAnnotationTool {
        ScreenshotAnnotationPreferences.startupTool()
    }

    private func invalidateInlineCursorRects() {
        guard let root = inlinePanel?.contentView as? ScreenshotAnnotationOverlayRoot else { return }
        inlinePanel?.invalidateCursorRects(for: root)
    }

    @objc private func toolChanged(_ sender: ScreenshotToolbarButton) {
        guard let tool = ScreenshotAnnotationTool(rawValue: sender.tag) else { return }
        if tool == .sticker { showStickerMenu(sender) }
        else { selectTool(tool) }
    }

    private func restoreStylePreferences(on canvas: ScreenshotAnnotationCanvas) {
        canvas.onTextEditingChanged = { [weak self] in self?.updateAnnotationToolHotKeys() }
        canvas.onElementClipboardChanged = { [weak self] in self?.updateAnnotationToolHotKeys() }
        canvas.onSelectedElementChanged = { [weak self] in
            self?.updateAnnotationToolHotKeys()
            self?.updatePaletteIcon()
            self?.updateMagnifierStyleHelp()
            if let tool = self?.canvas?.tool { self?.updateAdvancedToolButton(for: tool) }
        }
        let defaults = UserDefaults.standard
        ScreenshotAnnotationPreferences.migrateDiscardStyle(in: defaults)
        canvas.rectangleCornerRadiusPoints =
            ScreenshotAnnotationPreferences.rectangleCornerRadiusPoints(in: defaults)
        canvas.loadToolDefaults(from: defaults)
        if ScreenshotAnnotationPreferences.remembers(in: defaults) {
            if let opacity = defaults.object(forKey: ScreenshotAnnotationPreferences.highlighterOpacityKey) as? Int {
                canvas.setHighlighterOpacity(opacity)
            }
            canvas.arrowStyle = ScreenshotArrowStyle(rawValue: defaults.integer(
                forKey: ScreenshotAnnotationPreferences.arrowStyleKey)) ?? .rounded
            canvas.rectangleStyle = ScreenshotRectangleStyle(rawValue: defaults.integer(
                forKey: ScreenshotAnnotationPreferences.rectangleStyleKey)) ?? .roundedOutline
            canvas.ellipseStyle = ScreenshotEllipseStyle(rawValue: defaults.integer(
                forKey: ScreenshotAnnotationPreferences.ellipseStyleKey)) ?? .outline
            canvas.magnifierStyle = ScreenshotMagnifierStyle(rawValue: defaults.integer(
                forKey: ScreenshotAnnotationPreferences.magnifierStyleKey)) ?? .ellipse
            canvas.textStyle = ScreenshotTextStyle(rawValue: defaults.integer(
                forKey: ScreenshotAnnotationPreferences.textStyleKey))?.preferred ?? .outlinedShadow
        }
        canvas.onStrokePreferenceChanged = { tool, value in
            let preferences = ScreenshotAnnotationPreferences.self
            guard preferences.remembers() else { return }
            let key = tool == .arrow ? preferences.arrowScaleKey : preferences.rememberedWidthKey(for: tool)
            guard let key, tool == .arrow || defaults.object(forKey: preferences.defaultWidthKey(for: tool)) == nil
            else { return }
            defaults.set(Double(value), forKey: key)
        }
    }

    private func updateStyleHelp() {
        guard let canvas else { return }
        let hint = "箭头样式 · 当前：\(canvas.arrowStyle.title)"
        arrowStyleButton?.toolTip = hint
        arrowStyleButton?.setAccessibilityLabel("选择箭头样式")
        arrowStyleButton?.setAccessibilityValue(canvas.arrowStyle.title)
        let button = toolButtons[ScreenshotAnnotationTool.arrow.rawValue]
        let detail = canvas.arrowStyle == .withRectangle
            ? " · 拖箭尾或矩形四角调整，箭尖自动对准圆角"
            : ""
        button.toolTip = annotationToolHint(.arrow) + " · " + canvas.arrowStyle.title + detail
        button.setAccessibilityLabel(button.toolTip)
        rectangleStyleButton?.toolTip = "矩形样式 · 当前：\(canvas.rectangleStyle.title)"
        rectangleStyleButton?.setAccessibilityLabel("选择矩形样式")
        rectangleStyleButton?.setAccessibilityValue(canvas.rectangleStyle.title)
        let rectangle = toolButtons[ScreenshotAnnotationTool.rectangle.rawValue]
        rectangle.toolTip = annotationToolHint(.rectangle) + " · " + canvas.rectangleStyle.title
        rectangle.setAccessibilityLabel(rectangle.toolTip)
        ellipseStyleButton?.toolTip = "椭圆样式 · 当前：\(canvas.ellipseStyle.title)"
        ellipseStyleButton?.setAccessibilityLabel("选择椭圆样式")
        ellipseStyleButton?.setAccessibilityValue(canvas.ellipseStyle.title)
        let ellipse = toolButtons[ScreenshotAnnotationTool.ellipse.rawValue]
        ellipse.toolTip = annotationToolHint(.ellipse) + " · " + canvas.ellipseStyle.title
        ellipse.setAccessibilityLabel(ellipse.toolTip)
        textStyleButton?.toolTip = "文字样式 · 当前：\(canvas.textStyle.title)"
        textStyleButton?.setAccessibilityLabel("选择文字样式")
        textStyleButton?.setAccessibilityValue(canvas.textStyle.title)
        let text = toolButtons[ScreenshotAnnotationTool.text.rawValue]
        text.toolTip = annotationToolHint(.text) + " · " + canvas.textStyle.title + " · 双击已有文字可修改"
        text.setAccessibilityLabel(text.toolTip)
        updateMagnifierStyleHelp()
    }

    private func updateMagnifierStyleHelp() {
        guard let canvas else { return }
        let style = canvas.selectedMagnifierStyle ?? canvas.magnifierStyle
        magnifierStyleButton?.toolTip = "放大镜形状 · 当前：\(style.title)"
        magnifierStyleButton?.setAccessibilityLabel("选择放大镜形状")
        magnifierStyleButton?.setAccessibilityValue(style.title)
        let index = ScreenshotAnnotationTool.magnifier.rawValue
        guard toolButtons.indices.contains(index) else { return }
        let button = toolButtons[index]
        button.toolTip = annotationToolHint(.magnifier) + " · " + style.title
        button.setAccessibilityLabel(button.toolTip)
    }

    private func showStickerMenu(_ sender: ScreenshotToolbarButton) {
        popUpAppearanceMenu(stickerSourceMenu(), from: sender)
    }

    private func stickerSourceMenu() -> NSMenu {
        let menu = ScreenshotToolbarMenuItem.menu("插入贴图")
        menu.addItem(ScreenshotToolbarMenuItem.make("剪贴板图片",
            preview: ScreenshotToolbarMenuItem.symbol("doc.on.clipboard"),
            target: self, action: #selector(insertClipboardSticker)))
        menu.addItem(ScreenshotToolbarMenuItem.make("本地图片",
            preview: ScreenshotToolbarMenuItem.symbol("folder"),
            target: self, action: #selector(chooseStickerFile)))
        return menu
    }

    @objc private func insertClipboardSticker() {
        guard let presenter, clipboardImagePicker == nil else { return }
        let picker = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 640, height: 470),
            styleMask: [.titled], backing: .buffered, defer: false)
        picker.title = "剪贴板图片"
        picker.isReleasedWhenClosed = false
        picker.collectionBehavior = [.fullScreenAuxiliary]
        var selectedAsset: ScreenshotStickerAsset?
        let view = ScreenshotClipboardImagePicker(model: .shared, onSelect: { [weak self, weak presenter, weak picker] entry in
            guard self != nil, let presenter, let picker else { return nil }
            guard let data = AppController.shared.annotationImageData(for: entry),
                  let asset = ScreenshotStickerAsset.decode(data) else {
                return "这张图片当前不可用，请重新复制后再选择。"
            }
            selectedAsset = asset
            presenter.endSheet(picker, returnCode: .OK)
            return nil
        }, onCancel: { [weak presenter, weak picker] in
            if let presenter, let picker { presenter.endSheet(picker, returnCode: .cancel) }
        })
        picker.contentView = NSHostingView(rootView: view)
        clipboardImagePicker = picker
        choosingStickerFile = true
        updateAnnotationToolHotKeys()
        presenter.beginSheet(picker) { [weak self, weak picker] response in
            picker?.orderOut(nil)
            guard let self else { return }
            self.clipboardImagePicker = nil
            self.choosingStickerFile = false
            self.updateAnnotationToolHotKeys()
            if response == .OK, let asset = selectedAsset, !self.isDismissingAnnotations {
                self.prepareSticker(asset)
            }
        }
    }

    private func closeClipboardImagePicker() {
        guard let picker = clipboardImagePicker else { return }
        presenter?.endSheet(picker, returnCode: .cancel)
        picker.orderOut(nil)
        clipboardImagePicker = nil
        choosingStickerFile = false
    }

    @objc private func chooseStickerFile() {
        guard let presenter else { return }
        let panel = NSOpenPanel()
        panel.title = "选择贴图图片"
        panel.allowedContentTypes = [.png, .jpeg, .svg, .tiff, .heic, .gif, .bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        choosingStickerFile = true
        updateAnnotationToolHotKeys()
        panel.beginSheetModal(for: presenter) { [weak self] response in
            guard let self else { return }
            self.choosingStickerFile = false
            self.updateAnnotationToolHotKeys()
            guard response == .OK, let url = panel.url else { return }
            guard let asset = ScreenshotStickerAsset.fromFile(url) else {
                self.showInlineStatus("无法读取该图片，请选择 PNG、SVG 或 JPEG 等图片（最大 64 MB）。", dismissAfter: 5)
                return
            }
            self.prepareSticker(asset)
        }
    }

    private func prepareSticker(_ asset: ScreenshotStickerAsset) {
        selectTool(.sticker)
        canvas?.prepareSticker(asset)
        showInlineStatus("拖动放置贴图，或单击使用默认大小", dismissAfter: 4)
    }

    @objc private func showColorMenu(_ sender: ScreenshotToolbarButton) {
        guard let canvas else { return }
        let menu = ScreenshotToolbarMenuItem.menu("标注颜色")
        menu.autoenablesItems = false
        let current = canvas.selectedColor ?? canvas.annotationColor
        let colors: [ScreenshotAnnotationColor] = [.graphite, .red, .orange, .gold, .green, .teal, .blue, .violet, .white]
        for color in colors {
            let item = ScreenshotToolbarMenuItem.make(color.title,
                preview: color.menuSwatch(), selected: color == current,
                previewSize: CGSize(width: 26, height: 26),
                target: self, action: #selector(chooseAnnotationColor(_:)))
            item.tag = color.rawValue
            menu.addItem(item)
        }
        popUpAppearanceMenu(menu, from: sender)
        updatePaletteIcon()
    }

    @objc private func chooseAnnotationColor(_ sender: NSMenuItem) {
        guard let color = ScreenshotAnnotationColor(rawValue: sender.tag) else { return }
        appearanceMenu?.cancelTracking()
        canvas?.chooseColor(color)
    }

    @objc private func showHighlighterMenu(_ sender: NSButton) {
        guard let canvas else { return }
        let current = canvas.selectedHighlighterOpacity ?? canvas.highlighterOpacity
        let color = canvas.selectedColor ?? canvas.annotationColor
        let menu = ScreenshotToolbarMenuItem.menu("荧光笔不透明度")
        menu.autoenablesItems = false
        for level in Set([10, 25, 50, 75, 100, current]).sorted() {
            let item = ScreenshotToolbarMenuItem.make("\(level)% 不透明度",
                preview: color.highlighterPreview(opacity: level), selected: level == current,
                target: self, action: #selector(chooseHighlighterOpacity(_:)))
            item.tag = level
            menu.addItem(item)
        }
        popUpAppearanceMenu(menu, from: sender)
    }

    @objc private func chooseHighlighterOpacity(_ sender: NSMenuItem) {
        canvas?.setHighlighterOpacity(sender.tag, updateSelection: true)
        if ScreenshotAnnotationPreferences.remembers() {
            UserDefaults.standard.set(sender.tag, forKey: ScreenshotAnnotationPreferences.highlighterOpacityKey)
        }
        selectTool(.highlighter)
    }

    @objc private func showObscureMenu(_ sender: NSButton) {
        guard let canvas else { return }
        let mode = canvas.selectedObscure?.1 ?? canvas.obscureMode
        let strength = canvas.selectedObscure?.2 ?? canvas.obscureStrength
        let menu = ScreenshotToolbarMenuItem.menu("遮盖")
        menu.autoenablesItems = false
        for option in ScreenshotObscureMode.allCases {
            let item = ScreenshotToolbarMenuItem.make(option.title,
                preview: option.previewImage(strength: strength), selected: option == mode,
                target: self, action: #selector(chooseObscureOption(_:)))
            item.tag = option.rawValue * 10
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for level in 1...5 {
            let name = ["极轻", "轻", "适中", "强", "极强"][level - 1]
            let item = ScreenshotToolbarMenuItem.make(name,
                preview: mode.previewImage(strength: level), selected: level == strength,
                target: self, action: #selector(chooseObscureOption(_:)))
            item.tag = mode.rawValue * 10 + level
            item.toolTip = "\(mode.title) · \(name)"
            menu.addItem(item)
        }
        popUpAppearanceMenu(menu, from: sender)
    }

    @objc private func chooseObscureOption(_ sender: NSMenuItem) {
        guard let mode = ScreenshotObscureMode(rawValue: sender.tag / 10) else { return }
        let level = sender.tag % 10
        canvas?.chooseObscure(mode, strength: level == 0 ? nil : level)
        selectTool(.mosaic)
    }

    private func popUpAppearanceMenu(_ menu: NSMenu, from sender: NSButton) {
        closeScreenshotTextPopover()
        appearanceMenu = menu
        menu.popUp(positioning: nil, at: .zero, in: sender)
        appearanceMenu = nil
        (menu as? ScreenshotToolbarMenu)?.performPendingSelection()
    }

    @objc private func showMagnifierStyleMenu(_ sender: NSButton) {
        guard let canvas else { return }
        closeScreenshotTextPopover()
        let menu = ScreenshotToolbarMenuItem.menu("放大镜形状")
        menu.autoenablesItems = false
        let current = canvas.selectedMagnifierStyle ?? canvas.magnifierStyle
        for style in ScreenshotMagnifierStyle.allCases {
            let item = ScreenshotToolbarMenuItem.make(style.menuTitle,
                preview: style.previewImage, selected: current == style,
                target: self, action: #selector(chooseMagnifierStyleMenuItem(_:)))
            item.tag = style.rawValue
            item.toolTip = style.title
            menu.addItem(item)
        }
        popUpAppearanceMenu(menu, from: sender)
    }

    private func chooseMagnifierStyle(_ style: ScreenshotMagnifierStyle) {
        canvas?.chooseMagnifierStyle(style)
        if ScreenshotAnnotationPreferences.remembers() {
            UserDefaults.standard.set(style.rawValue,
                                      forKey: ScreenshotAnnotationPreferences.magnifierStyleKey)
        }
        selectTool(.magnifier)
        updateMagnifierStyleHelp()
    }

    @objc private func chooseMagnifierStyleMenuItem(_ item: NSMenuItem) {
        guard let style = ScreenshotMagnifierStyle(rawValue: item.tag) else { return }
        chooseMagnifierStyle(style)
    }

    @objc private func showTextStyleMenu(_ sender: NSButton) {
        guard let canvas else { return }
        closeScreenshotTextPopover()
        let menu = ScreenshotToolbarMenuItem.menu("文字样式")
        menu.autoenablesItems = false
        let current = canvas.selectedTextStyle ?? canvas.textStyle
        for style in ScreenshotTextStyle.allCases {
            let item = ScreenshotToolbarMenuItem.make(style.title,
                preview: style.previewImage(color: (canvas.selectedColor ?? canvas.annotationColor).color), selected: current == style,
                target: self, action: #selector(chooseTextStyleMenuItem(_:)))
            item.tag = style.rawValue
            item.toolTip = style.title
            menu.addItem(item)
        }
        textStyleMenu = menu
        defer { textStyleMenu = nil }
        popUpAppearanceMenu(menu, from: sender)
    }

    private func chooseTextStyle(_ style: ScreenshotTextStyle) {
        canvas?.chooseTextStyle(style)
        if ScreenshotAnnotationPreferences.remembers() {
            UserDefaults.standard.set(style.rawValue,
                                      forKey: ScreenshotAnnotationPreferences.textStyleKey)
        }
        selectTool(.text)
        updateStyleHelp()
    }

    @objc private func chooseTextStyleMenuItem(_ item: NSMenuItem) {
        guard let style = ScreenshotTextStyle(rawValue: item.tag) else { return }
        chooseTextStyle(style)
    }

    @objc private func showArrowStyleMenu(_ sender: NSButton) {
        guard let canvas else { return }
        closeScreenshotTextPopover()
        let menu = ScreenshotToolbarMenuItem.menu("箭头样式")
        menu.autoenablesItems = false
        let current = canvas.arrowStyle
        for style in ScreenshotArrowStyle.allCases {
            let item = ScreenshotToolbarMenuItem.make(style.menuTitle,
                preview: style.previewImage, selected: current == style,
                target: self, action: #selector(chooseArrowStyleMenuItem(_:)))
            item.tag = style.rawValue
            item.toolTip = style.title
            menu.addItem(item)
        }
        arrowStyleMenu = menu
        defer { arrowStyleMenu = nil }
        popUpAppearanceMenu(menu, from: sender)
    }

    private func chooseArrowStyle(_ style: ScreenshotArrowStyle) {
        guard let canvas else { return }
        canvas.arrowStyle = style
        if ScreenshotAnnotationPreferences.remembers() {
            UserDefaults.standard.set(style.rawValue,
                                      forKey: ScreenshotAnnotationPreferences.arrowStyleKey)
        }
        selectTool(.arrow)
        updateStyleHelp()
    }

    @objc private func chooseArrowStyleMenuItem(_ item: NSMenuItem) {
        guard let style = ScreenshotArrowStyle(rawValue: item.tag) else { return }
        chooseArrowStyle(style)
    }

    @objc private func showRectangleStyleMenu(_ sender: NSButton) {
        guard let canvas else { return }
        closeScreenshotTextPopover()
        let menu = ScreenshotToolbarMenuItem.menu("矩形样式")
        menu.autoenablesItems = false
        let current = canvas.rectangleStyle
        for style in ScreenshotRectangleStyle.allCases where style != .discard {
            let item = ScreenshotToolbarMenuItem.make(style.menuTitle,
                preview: style.previewImage, selected: current == style,
                target: self, action: #selector(chooseRectangleStyleMenuItem(_:)))
            item.tag = style.rawValue
            item.toolTip = style.title
            menu.addItem(item)
        }
        rectangleStyleMenu = menu
        defer { rectangleStyleMenu = nil }
        popUpAppearanceMenu(menu, from: sender)
    }

    private func chooseRectangleStyle(_ style: ScreenshotRectangleStyle) {
        guard let canvas else { return }
        canvas.rectangleStyle = style
        if ScreenshotAnnotationPreferences.remembers() {
            UserDefaults.standard.set(style.rawValue,
                                      forKey: ScreenshotAnnotationPreferences.rectangleStyleKey)
        }
        selectTool(.rectangle)
        updateStyleHelp()
    }

    @objc private func chooseRectangleStyleMenuItem(_ item: NSMenuItem) {
        guard let style = ScreenshotRectangleStyle(rawValue: item.tag) else { return }
        chooseRectangleStyle(style)
    }

    @objc private func showEllipseStyleMenu(_ sender: NSButton) {
        guard let canvas else { return }
        closeScreenshotTextPopover()
        let menu = ScreenshotToolbarMenuItem.menu("椭圆样式")
        menu.autoenablesItems = false
        let current = canvas.ellipseStyle
        for style in ScreenshotEllipseStyle.allCases {
            let item = ScreenshotToolbarMenuItem.make(style.menuTitle,
                preview: style.previewImage, selected: current == style,
                target: self, action: #selector(chooseEllipseStyleMenuItem(_:)))
            item.tag = style.rawValue
            item.toolTip = style.title
            menu.addItem(item)
        }
        ellipseStyleMenu = menu
        defer { ellipseStyleMenu = nil }
        popUpAppearanceMenu(menu, from: sender)
    }

    private func chooseEllipseStyle(_ style: ScreenshotEllipseStyle) {
        guard let canvas else { return }
        canvas.ellipseStyle = style
        if ScreenshotAnnotationPreferences.remembers() {
            UserDefaults.standard.set(style.rawValue,
                                      forKey: ScreenshotAnnotationPreferences.ellipseStyleKey)
        }
        selectTool(.ellipse)
        updateStyleHelp()
    }

    @objc private func chooseEllipseStyleMenuItem(_ item: NSMenuItem) {
        guard let style = ScreenshotEllipseStyle(rawValue: item.tag) else { return }
        chooseEllipseStyle(style)
    }

    @objc private func recognizeScreenshotText(_ sender: NSButton) {
        startScreenshotText(anchor: sender)
    }

    private func translationLanguageName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    private func translationMenuItem(_ title: String, choice: String,
                                     selected: Bool) -> NSMenuItem {
        let badge: String
        if choice == "both:auto" { badge = "文⇄A" }
        else if choice.hasSuffix(":auto") { badge = "自动" }
        else {
            let code = String(choice.split(separator: ":").last ?? "")
            if code.hasPrefix("zh") { badge = code.contains("Hant") ? "繁" : "简" }
            else { badge = String(code.split(separator: "-").first ?? "").uppercased() }
        }
        let item = ScreenshotToolbarMenuItem.make(title,
            preview: ScreenshotToolbarMenuItem.badge(badge), selected: selected,
            target: self, action: #selector(chooseScreenshotLanguage(_:)))
        item.representedObject = choice
        return item
    }

    @objc private func showTranslationLanguageMenu(_ sender: NSButton) {
        guard presenter != nil else { return }
        closeScreenshotTextPopover()
        let menu = ScreenshotToolbarMenuItem.menu("截图翻译语言")
        menu.autoenablesItems = false
        menu.addItem(translationMenuItem("自动中英",
                                          choice: "both:auto",
                                          selected: translationSourceOverride == nil
                                              && translationTargetOverride == nil))
        menu.addItem(.separator())
        let fallback = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"]
            .map(Locale.Language.init(identifier:))
        let languages = supportedTranslationLanguages.isEmpty
            ? fallback : supportedTranslationLanguages

        let sourceMenu = ScreenshotToolbarMenuItem.menu("原文语言")
        sourceMenu.addItem(translationMenuItem("自动识别", choice: "source:auto",
                                                selected: translationSourceOverride == nil))
        sourceMenu.addItem(.separator())
        let targetMenu = ScreenshotToolbarMenuItem.menu("译文语言")
        targetMenu.addItem(translationMenuItem("自动中英", choice: "target:auto",
                                                selected: translationTargetOverride == nil))
        targetMenu.addItem(.separator())
        for language in languages {
            let code = language.minimalIdentifier
            let name = translationLanguageName(language)
            sourceMenu.addItem(translationMenuItem(name, choice: "source:\(code)",
                selected: translationSourceOverride?.minimalIdentifier == code))
            targetMenu.addItem(translationMenuItem(name, choice: "target:\(code)",
                selected: translationTargetOverride?.minimalIdentifier == code))
        }
        menu.addItem(ScreenshotToolbarMenuItem.submenu("原文语言",
            preview: ScreenshotToolbarMenuItem.badge("文→"), choices: sourceMenu))
        menu.addItem(ScreenshotToolbarMenuItem.submenu("译文语言",
            preview: ScreenshotToolbarMenuItem.badge("→A"), choices: targetMenu))
        popUpAppearanceMenu(menu, from: sender)
    }

    @objc private func chooseScreenshotLanguage(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? String,
              let button = translationButton else { return }
        if choice == "both:auto" {
            translationSourceOverride = nil
            translationTargetOverride = nil
        } else if choice == "source:auto" {
            translationSourceOverride = nil
        } else if choice == "target:auto" {
            translationTargetOverride = nil
        } else if choice.hasPrefix("source:") {
            translationSourceOverride = Locale.Language(identifier: String(choice.dropFirst(7)))
        } else if choice.hasPrefix("target:") {
            translationTargetOverride = Locale.Language(identifier: String(choice.dropFirst(7)))
        } else { return }
        cancelScreenshotTranslation()
        if canvas?.hasTranslation == true { canvas?.toggleTranslation([]) }
        translateScreenshotText(button)
    }

    @objc private func translateScreenshotText(_ sender: NSButton) {
        guard #available(macOS 15.0, *) else {
            showInlineStatus("图片内翻译需要 macOS 15 或更新版本；可先识别文字并使用系统翻译。", dismissAfter: 5)
            return
        }
        guard presenter != nil, let canvas, !canvas.isCropping,
              !isRefreshingInlineSelection, !canvas.isAdjustingSelection else { return }
        closeScreenshotTextPopover()
        cancelScreenshotTranslation()
        if canvas.hasTranslation {
            canvas.toggleTranslation([])
            showInlineStatus("已恢复截图原文", dismissAfter: 3)
            return
        }
        let image: CGImage
        do { image = try canvas.renderedImage() }
        catch {
            showInlineStatus("无法读取截图：\(error.localizedDescription)", dismissAfter: 6)
            return
        }
        let requestID = UUID()
        translationRequestID = requestID
        updateCanvasScan()
        sender.isEnabled = false
        showInlineStatus("正在识别并翻译截图文字…")
        translationTask = Task { @MainActor [weak self] in
            do {
                let lines = try await ImageOCRService.recognizeLines(image)
                guard let self, self.translationRequestID == requestID else { return }
                guard !lines.isEmpty else {
                    self.finishScreenshotTranslation(requestID,
                        message: "没有识别到文字，请调整选区后重试。")
                    return
                }
                let text = lines.map(\.text).joined(separator: "\n")
                let detected = self.defaultScreenshotTranslationLanguages(for: text)
                let source = self.translationSourceOverride ?? detected.source
                let target = self.translationTargetOverride
                    ?? (self.translationSourceOverride == nil ? detected.target
                        : (source.languageCode?.identifier == "zh"
                            ? Locale.Language(identifier: "en")
                            : Locale.Language(identifier: "zh-Hans")))
                guard source.minimalIdentifier != target.minimalIdentifier else {
                    self.finishScreenshotTranslation(requestID,
                        message: "原文与译文语言相同，请通过翻译旁的箭头选择其他语言。")
                    return
                }
                self.showInlineStatus("已识别 \(lines.count) 行：\(self.translationLanguageName(source)) → \(self.translationLanguageName(target))…")
                let requests = lines.enumerated().map { index, line in
                    TranslationSession.Request(sourceText: line.text,
                                               clientIdentifier: String(index))
                }
                switch await LanguageAvailability().status(from: source, to: target) {
                case .installed:
                    if #available(macOS 26.0, *) {
                        let session = TranslationSession(installedSource: source, target: target)
                        let responses = try await session.translations(from: requests)
                        self.applyScreenshotTranslation(responses, lines: lines, requestID: requestID)
                    } else {
                        self.startScreenshotTranslationDownload(source: source, target: target,
                            requests: requests, lines: lines, requestID: requestID)
                    }
                case .supported:
                    guard self.translationRequestID == requestID else { return }
                    self.showInlineStatus("首次使用这组语言需要下载；请按系统提示操作。")
                    self.startScreenshotTranslationDownload(
                        source: source, target: target, requests: requests,
                        lines: lines, requestID: requestID
                    )
                case .unsupported:
                    self.finishScreenshotTranslation(requestID,
                        message: "这组原文和译文语言暂不支持互译，请重新选择。")
                @unknown default:
                    self.finishScreenshotTranslation(requestID,
                        message: "无法确认这组语言是否可用，请重新选择。")
                }
            } catch {
                guard let self, self.translationRequestID == requestID else { return }
                self.finishScreenshotTranslation(requestID,
                    message: "翻译失败：\(error.localizedDescription)")
            }
        }
    }

    @available(macOS 15.0, *)
    private func startScreenshotTranslationDownload(
        source: Locale.Language, target: Locale.Language,
        requests: [TranslationSession.Request], lines: [ImageOCRLine],
        requestID: UUID
    ) {
        guard let root = presenter?.contentView,
              translationRequestID == requestID else { return }
        translationDownloadHost?.removeFromSuperview()
        let runner = ScreenshotTranslationDownloadView(
            source: source, target: target, requests: requests,
            onComplete: { [weak self] result in
                guard let self, self.translationRequestID == requestID else { return }
                switch result {
                case .success(let responses):
                    self.applyScreenshotTranslation(responses, lines: lines,
                                                    requestID: requestID)
                case .failure(let error):
                    self.finishScreenshotTranslation(requestID,
                        message: "翻译失败：\(error.localizedDescription)")
                }
            }
        )
        let host = NSHostingView(rootView: runner)
        host.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        host.wantsLayer = true
        host.layer?.opacity = 0
        root.addSubview(host)
        translationDownloadHost = host
    }

    @available(macOS 15.0, *)
    private func applyScreenshotTranslation(
        _ responses: [TranslationSession.Response], lines: [ImageOCRLine],
        requestID: UUID
    ) {
        guard translationRequestID == requestID, let canvas else { return }
        let byIndex = Dictionary(uniqueKeysWithValues: responses.compactMap { response
            -> (Int, String)? in
            guard let id = response.clientIdentifier, let index = Int(id) else { return nil }
            return (index, response.targetText)
        })
        let translated = lines.enumerated().compactMap { index, line
            -> ScreenshotTranslatedLine? in
            guard let text = byIndex[index]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return ScreenshotTranslatedLine(sourceRect: line.rect, text: text)
        }
        guard !translated.isEmpty else {
            finishScreenshotTranslation(requestID,
                message: "翻译没有返回文字，请稍后重试。")
            return
        }
        finishScreenshotTranslation(requestID)
        canvas.toggleTranslation(ScreenshotTranslationLayout.arrange(translated,
            imageSize: CGSize(width: canvas.image.width, height: canvas.image.height),
            pixelsPerPoint: canvas.strokePixelsPerPoint))
    }

    private func startScreenshotText(anchor: NSButton) {
        guard presenter != nil, let canvas, !canvas.isCropping,
              !isRefreshingInlineSelection, !canvas.isAdjustingSelection else { return }
        cancelScreenshotTranslation()
        closeScreenshotTextPopover()
        let image: CGImage
        do { image = try canvas.renderedImage() }
        catch {
            showScreenshotTextPopover(
                ScreenshotTextMessageView(title: "识别文字失败",
                                          detail: error.localizedDescription,
                                          isLoading: false, onRetry: nil),
                anchor: anchor
            )
            return
        }
        let requestID = UUID()
        screenshotTextRequestID = requestID
        screenshotTextLoading = true
        updateCanvasScan()
        showScreenshotTextPopover(
            ScreenshotTextMessageView(title: "识别文字",
                                      detail: "正在识别当前截图中的文字…",
                                      isLoading: true, onRetry: nil),
            anchor: anchor
        )
        screenshotTextTask = Task { @MainActor [weak self] in
            do {
                let recognized = try await ImageOCRService.recognize(image)
                guard let self, self.screenshotTextRequestID == requestID,
                      self.screenshotTextPopover?.isShown == true else { return }
                self.screenshotTextLoading = false
                self.updateCanvasScan()
                let text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.showScreenshotTextResultMessage(
                        title: "没有识别到文字", detail: "请调整选区后再试。",
                        anchor: anchor
                    )
                    return
                }
                self.updateScreenshotTextPopover(
                    ScreenshotOCRResultView(
                        text: text,
                        onCopy: { AppController.shared.copyScreenshotRecognizedText($0) }
                    )
                )
            } catch {
                guard let self, self.screenshotTextRequestID == requestID,
                      self.screenshotTextPopover?.isShown == true else { return }
                self.showScreenshotTextResultMessage(
                    title: "识别文字失败", detail: error.localizedDescription,
                    anchor: anchor
                )
            }
        }
    }

    private func showScreenshotTextResultMessage(
        title: String, detail: String,
        anchor: NSButton
    ) {
        screenshotTextLoading = false
        updateCanvasScan()
        updateScreenshotTextPopover(
            ScreenshotTextMessageView(
                title: title, detail: detail, isLoading: false,
                onRetry: { [weak self, weak anchor] in
                    guard let anchor else { return }
                    self?.startScreenshotText(anchor: anchor)
                }
            )
        )
    }

    private func defaultScreenshotTranslationLanguages(
        for text: String
    ) -> (source: Locale.Language, target: Locale.Language) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage
        let chineseCount = text.unicodeScalars.filter {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }.count
        let latinCount = text.unicodeScalars.filter {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }.count
        // A mixed screenshot may include one Chinese label in an English
        // paragraph (or an English product name in Chinese copy). Prefer the
        // dominant language instead of treating any Han glyph as Chinese.
        let mostlyChinese = chineseCount > 0 &&
            ((detected == .simplifiedChinese || detected == .traditionalChinese)
                ? latinCount <= chineseCount * 3 : chineseCount * 2 >= latinCount)
        if mostlyChinese {
            return (Locale.Language(identifier: detected == .traditionalChinese
                                    ? "zh-Hant" : "zh-Hans"),
                    Locale.Language(identifier: "en"))
        }
        if latinCount > 0 || detected == .english {
            let source = detected == .english || detected == nil
                || detected == .simplifiedChinese || detected == .traditionalChinese
                ? "en" : detected!.rawValue
            return (Locale.Language(identifier: source),
                    Locale.Language(identifier: "zh-Hans"))
        }
        if let detected {
            return (Locale.Language(identifier: detected.rawValue),
                    Locale.Language(identifier: "zh-Hans"))
        }
        return (Locale.Language(identifier: "en"), Locale.Language(identifier: "zh-Hans"))
    }

    private func restoreTranslationButton() {
        guard let button = translationButton else { return }
        // ScreenshotToolbarButton draws its icon in a fixed NSImageView.
        // Setting NSButton.image here would draw a second icon over it.
        if #available(macOS 15.0, *) { button.isEnabled = true }
    }

    private func updateCanvasScan() {
        canvas?.scanMessage = translationRequestID != nil ? "正在识别并翻译…"
            : (screenshotTextLoading ? "正在识别文字…" : nil)
    }

    private func cancelScreenshotTranslation() {
        guard translationRequestID != nil else { return }
        translationRequestID = nil
        updateCanvasScan()
        translationTask?.cancel()
        translationTask = nil
        translationDownloadHost?.removeFromSuperview()
        translationDownloadHost = nil
        restoreTranslationButton()
        showInlineStatus("已取消翻译", dismissAfter: 2)
    }

    private func finishScreenshotTranslation(_ requestID: UUID, message: String? = nil) {
        guard translationRequestID == requestID else { return }
        translationRequestID = nil
        updateCanvasScan()
        translationTask = nil
        translationDownloadHost?.removeFromSuperview()
        translationDownloadHost = nil
        restoreTranslationButton()
        if let message { showInlineStatus(message, dismissAfter: 5) }
        else { clearInlineStatus() }
    }

    private func clearInlineStatus() {
        inlineStatusDismissTask?.cancel()
        inlineStatusDismissTask = nil
        inlineStatusLabel?.removeFromSuperview()
        inlineStatusLabel = nil
    }

    private func showInlineStatus(_ message: String, dismissAfter seconds: Double? = nil) {
        guard let root = presenter?.contentView, let toolbar = editorToolbar else { return }
        inlineStatusDismissTask?.cancel()
        let label: NSTextField
        if let inlineStatusLabel {
            label = inlineStatusLabel
        } else {
            label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(0.94).cgColor
            label.layer?.cornerRadius = 7
            root.addSubview(label)
            inlineStatusLabel = label
        }
        label.stringValue = message
        let width = min(root.bounds.width - 24,
                        max(220, min(440, CGFloat(message.count) * 11 + 24)))
        label.frame.size = CGSize(width: width, height: 28)
        positionInlineStatus(near: toolbar.frame, in: root.bounds)
        if let seconds {
            inlineStatusDismissTask = Task { @MainActor [weak self, weak label] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self,
                      self.inlineStatusLabel === label else { return }
                label?.removeFromSuperview()
                self.inlineStatusLabel = nil
            }
        }
    }

    private func positionInlineStatus(near toolbarFrame: CGRect, in bounds: CGRect) {
        guard let label = inlineStatusLabel else { return }
        let x = min(max(12, toolbarFrame.midX - label.frame.width / 2),
                    bounds.maxX - label.frame.width - 12)
        let above = toolbarFrame.maxY + 7
        let y = above + label.frame.height <= bounds.maxY - 8
            ? above : max(8, toolbarFrame.minY - label.frame.height - 7)
        label.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func handleInlineEscape() {
        if canvas?.isCropping == true {
            canvas?.cancelCrop()
        } else if let appearanceMenu {
            appearanceMenu.cancelTracking()
        } else if let arrowStyleMenu {
            arrowStyleMenu.cancelTracking()
        } else if let rectangleStyleMenu {
            rectangleStyleMenu.cancelTracking()
        } else if let ellipseStyleMenu {
            ellipseStyleMenu.cancelTracking()
        } else if let textStyleMenu {
            textStyleMenu.cancelTracking()
        } else if screenshotTextPopover != nil {
            closeScreenshotTextPopover()
        } else if translationRequestID != nil {
            cancelScreenshotTranslation()
        } else if canvas?.isEditingText == true {
            canvas?.discardText()
        } else if canvas?.cancelPendingAnnotation() == true {
            updateAnnotationToolHotKeys()
        } else {
            cancel()
        }
    }

    private func updateAnnotationToolHotKeys() {
        let enabled = inlinePanel != nil && !shortcutsSuspendedForScreenshot && canvas?.isEditingText != true
            && canvas?.isCropping != true
            && screenshotTextPopover == nil && presenter?.attachedSheet == nil
            && !choosingStickerFile && !isDismissingAnnotations && !isShowingSettings
            && fileExportPhase != .choosingDestination
        for (tool, hotKey) in annotationToolHotKeys {
            if enabled, let action = tool.shortcutAction {
                _ = hotKey.register(AppController.shared.shortcut(for: action), allowsPrintableKey: true)
            } else { hotKey.unregister() }
        }
        if enabled, canvas?.isBuildingPenPath == true { _ = penFinishHotKey.registerReturn() }
        else { penFinishHotKey.unregister() }
        if enabled, canvas?.canCopySelectedElement == true {
            _ = elementCopyHotKey.register(AppShortcut(keyCode: 8, modifiers: .command, keyLabel: "C"))
        } else { elementCopyHotKey.unregister() }
        if enabled, NSPasteboard.general.availableType(from: [ScreenshotAnnotationCanvas.elementPasteboardType]) != nil {
            _ = elementPasteHotKey.register(AppShortcut(keyCode: 9, modifiers: .command, keyLabel: "V"))
        } else { elementPasteHotKey.unregister() }
    }

    private func triggerElementClipboard(paste: Bool) {
        guard inlinePanel?.isVisible == true, !shortcutsSuspendedForScreenshot,
              !isShowingSettings, screenshotTextPopover == nil, !choosingStickerFile,
              fileExportPhase != .choosingDestination, presenter?.attachedSheet == nil else { return }
        if paste { _ = canvas?.pasteElement() } else { _ = canvas?.copySelectedElement() }
    }

    private func registerScreenshotToolHotKeys() {
        isDismissingAnnotations = false
        updateAnnotationToolHotKeys()
        let actions: [(GlobalHotKey, AppShortcutAction)] = [
            (screenshotOCRHotKey, .recognizeImageText),
            (screenshotTranslationHotKey, .translateScreenshot),
            (screenshotPinHotKey, .togglePinImage),
            (screenshotExportHotKey, .saveImageToFile)
        ]
        let unavailable = actions.compactMap { hotKey, action -> String? in
            let shortcut = AppController.shared.shortcut(for: action)
            return hotKey.register(shortcut, allowsUnmodified: true)
                ? nil : shortcut.displayName
        }
        if !unavailable.isEmpty {
            showInlineStatus("快捷键 \(unavailable.joined(separator: "、")) 被占用；可点击对应工具按钮。",
                             dismissAfter: 5)
        }
    }

    private func unregisterScreenshotToolHotKeys() {
        elementCopyHotKey.unregister()
        elementPasteHotKey.unregister()
        screenshotOCRHotKey.unregister()
        screenshotTranslationHotKey.unregister()
        screenshotPinHotKey.unregister()
        screenshotExportHotKey.unregister()
    }

    private func handleScreenshotToolShortcut(_ event: NSEvent) -> Bool {
        guard !shortcutsSuspendedForScreenshot, canvas?.isCropping != true,
              !isShowingSettings, canvas?.isEditingText != true, screenshotTextPopover == nil,
              presenter?.attachedSheet == nil, !choosingStickerFile else { return false }
        if let action = AppShortcutPreference.annotationAction(
            keyCode: event.keyCode, modifiers: event.modifierFlags, inputActive: false,
            shortcuts: AppController.shared.shortcuts),
           let tool = ScreenshotAnnotationTool.allCases.first(where: { $0.shortcutAction == action }) {
            selectTool(tool)
            return true
        }
        let actions: [(AppShortcutAction, () -> Void)] = [
            (.recognizeImageText, { [weak self] in self?.triggerScreenshotOCR() }),
            (.translateScreenshot, { [weak self] in self?.triggerScreenshotTranslation() }),
            (.togglePinImage, { [weak self] in self?.triggerScreenshotPin() })
        ]
        for (action, trigger) in actions {
            if AppController.shared.shortcut(for: action).matches(
                keyCode: event.keyCode, modifiers: event.modifierFlags
            ) {
                trigger()
                return true
            }
        }
        return false
    }

    private func triggerScreenshotOCR() {
        guard presenter != nil, canvas?.isEditingText != true,
              let ocrButton else { return }
        recognizeScreenshotText(ocrButton)
    }

    private func triggerScreenshotTranslation() {
        guard presenter != nil, canvas?.isEditingText != true,
              let translationButton else { return }
        if #available(macOS 15.0, *), !translationButton.isEnabled { return }
        translateScreenshotText(translationButton)
    }

    private func triggerScreenshotPin() {
        guard presenter != nil, canvas?.isEditingText != true,
              let pinButton, pinButton.isEnabled else { return }
        pinScreenshot(pinButton)
    }

    private func showScreenshotTextPopover<Content: View>(
        _ content: Content, anchor: NSButton
    ) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: AnyView(content))
        screenshotTextPopover = popover
        updateAnnotationToolHotKeys()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func updateScreenshotTextPopover<Content: View>(_ content: Content) {
        guard let popover = screenshotTextPopover, popover.isShown else { return }
        popover.contentViewController = NSHostingController(rootView: AnyView(content))
    }

    private func closeScreenshotTextPopover() {
        screenshotTextRequestID = nil
        screenshotTextLoading = false
        updateCanvasScan()
        screenshotTextTask?.cancel()
        screenshotTextTask = nil
        let popover = screenshotTextPopover
        screenshotTextPopover = nil
        popover?.delegate = nil
        popover?.close()
        updateAnnotationToolHotKeys()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
              popover === screenshotTextPopover else { return }
        closeScreenshotTextPopover()
    }

    @objc private func undo() { canvas?.undo() }
    @objc private func toggleCrop() {
        guard let canvas else { return }
        if canvas.isCropping { _ = canvas.applyCrop(); return }
        closeScreenshotTextPopover()
        cancelScreenshotTranslation()
        canvas.beginCrop()
        window?.makeFirstResponder(canvas)
        showInlineStatus("裁剪：拖动框选，拖动边角调整；回车确认，Esc 取消。", dismissAfter: 5)
    }

    private func updateCropControls() {
        let cropping = canvas?.isCropping == true
        if cropping, cropDisabledControls.isEmpty, let editorToolbar {
            func disable(_ view: NSView) {
                if let button = view as? NSButton,
                   button !== cropButton, button !== saveButton, button !== cancelButton {
                    cropDisabledControls.append((button, button.isEnabled))
                    button.isEnabled = false
                }
                view.subviews.forEach(disable)
            }
            disable(editorToolbar)
        } else if !cropping {
            for (button, enabled) in cropDisabledControls { button.isEnabled = enabled }
            cropDisabledControls.removeAll()
        }
        cropButton?.isSelectedTool = cropping
        for button in toolButtons {
            button.isSelectedTool = !cropping && button.tag == canvas?.tool.rawValue
        }
        let saveHint = cropping ? "应用裁剪（回车）" : "保存并复制标注图片"
        saveButton?.toolTip = saveHint
        saveButton?.setAccessibilityLabel(saveHint)
        cancelButton?.toolTip = cropping ? "取消裁剪（Esc）" : "取消标注"
        cancelButton?.setAccessibilityLabel(cancelButton?.toolTip)
        if let button = saveButton as? ScreenshotToolbarButton,
           let icon = cropping
                ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "应用裁剪")
                : providedToolbarIcon(.copyCheck) {
            button.replaceIcon(icon)
        }
    }

    @objc private func cancel() {
        if canvas?.isCropping == true { canvas?.cancelCrop(); return }
        if inlinePanel != nil {
            onCancelInline?()
            dismissInline()
        } else {
            window?.close()
        }
    }

    @objc private func save() {
        if canvas?.isCropping == true { _ = canvas?.applyCrop(); return }
        guard let onSave else { return }
        finishScreenshot(onSave)
    }

    private var canExportImage: Bool {
        guard let presenter, let canvas else { return false }
        return !canvas.isCropping && presenter.attachedSheet == nil && !isShowingSettings && fileExportPhase == nil
            && !choosingStickerFile && !isRefreshingInlineSelection && !canvas.isAdjustingSelection
    }

    @objc private func exportImageToFile() {
        guard canExportImage, let presenter, let canvas else { return }
        let title = inlinePanel == nil ? "标注图片" : "截图"
        let panel = ImageFileExport.makePanel(name: ImageFileExport.suggestedName(title))
        fileExportPhase = .choosingDestination
        closeScreenshotTextPopover()
        unregisterScreenshotToolHotKeys()
        panel.beginSheetModal(for: presenter) { [weak self, weak presenter] response in
            Task { @MainActor in
                guard let self, let presenter, self.presenter === presenter else { return }
                let destination = ImageFileExport.destination(in: panel, response: response)
                self.fileExportPhase = destination == nil ? nil : .writing
                if self.inlinePanel != nil && !self.isShowingSettings {
                    self.registerScreenshotToolHotKeys()
                }
                guard let destination else { return }
                defer { if self.presenter === presenter { self.fileExportPhase = nil } }
                do {
                    let image = try canvas.renderedImage()
                    try await Task.detached(priority: .userInitiated) {
                        guard let data = LongScreenshotOutput.png(image) else { throw MacScreenshotError.noImage }
                        try ImageFileExport.write(data, to: destination)
                    }.value
                } catch {
                    if self.presenter === presenter {
                        self.showInlineStatus("保存图片失败：\(error.localizedDescription)", dismissAfter: 5)
                    }
                }
            }
        }
    }

    @objc func startLongScreenshot() {
        guard let panel = inlinePanel, let canvas, onStartLongScreenshot != nil,
              !isRefreshingInlineSelection, !canvas.isAdjustingSelection,
              panel.attachedSheet == nil else { return }
        if canvas.hasChanges {
            let alert = NSAlert()
            alert.messageText = "以当前选区开始长截图？"
            alert.informativeText = "长截图会从当前屏幕重新采集。继续后，本次截图里的标注会清除。"
            alert.addButton(withTitle: "开始长截图")
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1B}"
            alert.beginSheetModal(for: panel) { [weak self, weak panel] response in
                guard response == .alertFirstButtonReturn, let panel else { return }
                self?.prepareLongScreenshot(from: panel)
            }
        } else {
            prepareLongScreenshot(from: panel)
        }
    }

    private func prepareLongScreenshot(from panel: NSPanel) {
        guard inlinePanel === panel, !isRefreshingInlineSelection,
              let selected = inlineSourceFrame, let start = onStartLongScreenshot,
              let windowID = CGWindowID(exactly: panel.windowNumber) else { return }
        let area = selected.intersection(panel.frame)
        guard !area.isNull, area.width > 0, area.height > 0 else { return }
        closeScreenshotTextPopover()
        cancelScreenshotTranslation()
        isRefreshingInlineSelection = true
        saveButton?.isEnabled = false
        longScreenshotButton?.isEnabled = false
        showInlineStatus("正在准备长截图…")
        Task { @MainActor [weak self, weak panel] in
            do {
                let image = try await MacScreenshotCapture.captureRegionExcludingSelector(
                    area, selectorWindowID: windowID
                )
                guard let self, let panel, self.inlinePanel === panel else { return }
                guard self.canvas?.isAdjustingSelection != true else {
                    self.finishLongScreenshotPreparation("选区正在调整，请松开鼠标后重试。")
                    return
                }
                let source = MacScreenshotCapture.sourceApp(for: area, excludingWindowID: windowID)
                let frame = MacScreenshotFrame(image: image, sourceFrame: area, source: source,
                    selectionPanel: nil, isWindowCapture: false, frozenDisplay: nil)
                if start(frame) {
                    self.dismissInline(notifyDismissal: false)
                } else {
                    self.finishLongScreenshotPreparation("请选择足够大的可滚动区域。")
                }
            } catch {
                guard let self, let panel, self.inlinePanel === panel else { return }
                self.finishLongScreenshotPreparation(error.localizedDescription)
            }
        }
    }

    private func finishLongScreenshotPreparation(_ message: String) {
        isRefreshingInlineSelection = false
        saveButton?.isEnabled = true
        longScreenshotButton?.isEnabled = true
        showInlineStatus(message, dismissAfter: 5)
    }

    @objc private func pinScreenshot(_ sender: NSButton) {
        guard let onPin else { return }
        finishScreenshot(onPin)
    }

    private func finishScreenshot(_ action: (MacScreenshotImage, ScreenshotEditPayload?) -> Bool) {
        guard let canvas, let presenter = inlinePanel ?? window,
              !isRefreshingInlineSelection, !canvas.isAdjustingSelection else { return }
        do {
            let image = try canvas.export(maximumBytes: maximumBytes)
            let editable = try canvas.editPayload(maximumBytes: maximumBytes)
            guard action(image, editable) else {
                let alert = NSAlert()
                alert.messageText = "未能保存截图"
                alert.informativeText = saveFailureMessage?()
                    ?? "截图未能写入历史，请重试。"
                alert.beginSheetModal(for: presenter)
                return
            }
            if inlinePanel != nil { dismissInline() }
            else { window?.close() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法保存标注截图"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: presenter)
        }
    }

    private func dismissInline(notifyDismissal: Bool = true) {
        isShowingSettings = false
        fileExportPhase = nil
        isDismissingAnnotations = true
        closeClipboardImagePicker()
        updateAnnotationToolHotKeys()
        appearanceMenu?.cancelTracking()
        appearanceMenu = nil
        arrowStyleMenu?.cancelTracking()
        arrowStyleMenu = nil
        rectangleStyleMenu?.cancelTracking()
        rectangleStyleMenu = nil
        ellipseStyleMenu?.cancelTracking()
        ellipseStyleMenu = nil
        textStyleMenu?.cancelTracking()
        textStyleMenu = nil
        unregisterScreenshotToolHotKeys()
        closeScreenshotTextPopover()
        cancelScreenshotTranslation()
        translationLanguagesTask?.cancel()
        translationLanguagesTask = nil
        supportedTranslationLanguages = []
        translationSourceOverride = nil
        translationTargetOverride = nil
        clearInlineStatus()
        if let inlineKeyMonitor {
            NSEvent.removeMonitor(inlineKeyMonitor)
            self.inlineKeyMonitor = nil
        }
        if let inlineGlobalEscapeMonitor {
            NSEvent.removeMonitor(inlineGlobalEscapeMonitor)
            self.inlineGlobalEscapeMonitor = nil
        }
        inlinePanel?.orderOut(nil)
        inlinePanel = nil
        inlineSourceFrame = nil
        isRefreshingInlineSelection = false
        onStartLongScreenshot = nil
        onCancelInline = nil
        let onDismiss = onDismissInline
        onDismissInline = nil
        canvas = nil
        onSave = nil
        onPin = nil
        saveFailureMessage = nil
        toolButtons = []
        advancedToolButton = nil
        advancedToolOptionsButton = nil
        arrowStyleButton = nil
        rectangleStyleButton = nil
        ellipseStyleButton = nil
        textStyleButton = nil
        magnifierStyleButton = nil
        undoButton = nil
        saveButton = nil
        ocrButton = nil
        translationButton = nil
        pinButton = nil
        longScreenshotButton = nil
        editorToolbar = nil
        colorPaletteButton = nil
        cropButton = nil
        cancelButton = nil
        cropDisabledControls.removeAll()
        guard notifyDismissal else { return }
        onDismiss?()
        DispatchQueue.main.async { [weak self] in
            if self?.window == nil && self?.inlinePanel == nil
                && !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) })
                && !SettingsWindowController.shared.hasVisibleWindow {
                _ = NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        closeClipboardImagePicker()
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closeScreenshotTextPopover()
        cancelScreenshotTranslation()
        translationLanguagesTask?.cancel()
        translationLanguagesTask = nil
        supportedTranslationLanguages = []
        translationSourceOverride = nil
        translationTargetOverride = nil
        clearInlineStatus()
        if let inlineKeyMonitor {
            NSEvent.removeMonitor(inlineKeyMonitor)
            self.inlineKeyMonitor = nil
        }
        appearanceMenu?.cancelTracking()
        appearanceMenu = nil
        arrowStyleMenu?.cancelTracking()
        arrowStyleMenu = nil
        rectangleStyleMenu?.cancelTracking()
        rectangleStyleMenu = nil
        ellipseStyleMenu?.cancelTracking()
        ellipseStyleMenu = nil
        textStyleMenu?.cancelTracking()
        textStyleMenu = nil
        arrowStyleButton = nil
        rectangleStyleButton = nil
        ellipseStyleButton = nil
        textStyleButton = nil
        magnifierStyleButton = nil
        isShowingSettings = false
        fileExportPhase = nil
        window = nil
        canvas = nil
        onSave = nil
        onPin = nil
        saveFailureMessage = nil
        toolButtons = []
        advancedToolButton = nil
        advancedToolOptionsButton = nil
        undoButton = nil
        saveButton = nil
        ocrButton = nil
        translationButton = nil
        pinButton = nil
        longScreenshotButton = nil
        editorToolbar = nil
        colorPaletteButton = nil
        cropButton = nil
        cancelButton = nil
        cropDisabledControls.removeAll()
        let onClose = onCloseWindow
        onCloseWindow = nil
        onClose?()
        guard !(notification.object is LongScreenshotPanel) else { return }
        DispatchQueue.main.async { [weak self] in
            if self?.window == nil && self?.inlinePanel == nil
                && !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) })
                && !SettingsWindowController.shared.hasVisibleWindow {
                _ = NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
