import AppKit
import Carbon
import ImageIO
import QuartzCore
import ScreenCaptureKit
import UniformTypeIdentifiers

enum MacScreenshotMode: Equatable {
    case region, screen, long

    var title: String {
        switch self {
        case .region: "截图"
        case .screen: "整个屏幕截图"
        case .long: "长截图"
        }
    }
}

struct MacScreenshotImage {
    let data: Data
    let type: String
    let sourceFrame: CGRect?

    init(data: Data, type: String, sourceFrame: CGRect? = nil) {
        self.data = data
        self.type = type
        self.sourceFrame = sourceFrame
    }
}

struct MacScreenshotFrame {
    let image: CGImage
    let sourceFrame: CGRect
    let source: MacScreenshotSource
    let selectionPanel: NSPanel?
    let isWindowCapture: Bool
    let frozenDisplay: MacScreenshotFrozenDisplay?
}

enum ScreenshotFreezePreference {
    static let enabledKey = "freezeDesktopDuringScreenshot"
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

enum ScreenshotWindowShadowPreference {
    static let enabledKey = "includeWindowShadowInScreenshot"
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? false
    }
}

struct MacScreenshotFrozenDisplay {
    let screenFrame: CGRect
    let image: CGImage

    func crop(_ appKitRect: CGRect) throws -> (frame: CGRect, image: CGImage) {
        let frame = appKitRect.intersection(screenFrame)
        guard frame.width >= 1, frame.height >= 1 else {
            throw MacScreenshotError.noImage
        }
        let localRect = CGRect(
            x: frame.minX - screenFrame.minX,
            y: screenFrame.maxY - frame.maxY,
            width: frame.width, height: frame.height
        )
        let pixels = MacScreenshotGeometry.pixelCropRect(
            localRect,
            imageSize: CGSize(width: image.width, height: image.height),
            displaySize: screenFrame.size
        )
        guard pixels.width >= 1, pixels.height >= 1,
              let cropped = image.cropping(to: pixels) else {
            throw MacScreenshotError.noImage
        }
        // Cropping rounds outward to whole source pixels. Use the matching
        // point bounds too, otherwise the editor resamples those pixels back
        // into the fractional requested rectangle and changes glyph edges.
        let scaleX = CGFloat(image.width) / screenFrame.width
        let scaleY = CGFloat(image.height) / screenFrame.height
        let alignedFrame = CGRect(x: screenFrame.minX + pixels.minX / scaleX,
            y: screenFrame.maxY - pixels.maxY / scaleY,
            width: pixels.width / scaleX, height: pixels.height / scaleY)
        return (alignedFrame, cropped)
    }
}

struct MacScreenshotWindowCandidate {
    let id: CGWindowID
    let hitFrame: CGRect

    static func windowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    static func selectable(from info: [[String: Any]], excludingPID: pid_t,
                           includingWindowIDs: Set<CGWindowID> = []) -> [Self] {
        info.compactMap { item in
            guard let number = item[kCGWindowNumber as String] as? NSNumber,
                  let pid = item[kCGWindowOwnerPID as String] as? NSNumber,
                  (pid.int32Value != excludingPID || includingWindowIDs.contains(number.uint32Value)),
                  let layer = item[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 30, frame.height >= 30 else { return nil }
            return Self(id: number.uint32Value, hitFrame: frame)
        }
    }

    @MainActor static var capturableAppWindowIDs: Set<CGWindowID> {
        // Keep the selector and floating overlays excluded. Ordinary app
        // windows, including the image editor, can themselves be screenshotted.
        guard let app = NSApp else { return [] }
        return Set(app.windows.filter {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.windowNumber > 0
        }.map { CGWindowID($0.windowNumber) })
    }

    /// Preload every window the selector can actually hit. Auxiliary windows
    /// (including transparent, full-screen HUDs) are not selection candidates
    /// and must not discard the underlying window's frozen snapshot.
    static func reachable(in ordered: [Self]) -> [Self] {
        ordered.enumerated().compactMap { index, candidate in
            MacScreenshotFrozenWindow.visibleParts(of: candidate.hitFrame,
                occludedBy: ordered.prefix(index).map(\.hitFrame)).isEmpty ? nil : candidate
        }
    }
}

struct MacScreenshotFrozenWindow {
    let image: CGImage
    let frame: CGRect
    var visibleRects: [CGRect] = []

    /// Window and display requests can finish on different video frames.
    /// Preserve the exact pixels already shown in the frozen desktop wherever
    /// this window was visible. Hidden parts still come from its isolated
    /// snapshot, so foreground windows never leak into the selected window.
    func matching(_ displays: [CGDirectDisplayID: MacScreenshotFrozenDisplay]) -> Self {
        guard !visibleRects.isEmpty, !displays.isEmpty,
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let sx = CGFloat(image.width) / frame.width, sy = CGFloat(image.height) / frame.height
        for visible in visibleRects {
            for display in displays.values {
                guard let crop = try? display.crop(visible) else { continue }
                let destination = CGRect(x: (crop.frame.minX - frame.minX) * sx,
                    y: (crop.frame.minY - frame.minY) * sy, width: crop.frame.width * sx, height: crop.frame.height * sy)
                let visiblePart = visible.intersection(display.screenFrame)
                let clip = CGRect(x: (visiblePart.minX - frame.minX) * sx,
                    y: (visiblePart.minY - frame.minY) * sy,
                    width: visiblePart.width * sx, height: visiblePart.height * sy)
                context.saveGState()
                context.clip(to: clip)
                context.setBlendMode(.sourceIn) // Keep native window alpha, rounded corners and shadow.
                context.interpolationQuality = .none
                context.draw(crop.image, in: destination)
                context.restoreGState()
            }
        }
        guard let image = context.makeImage() else { return self }
        return Self(image: image, frame: frame)
    }

    static func visibleParts(of frame: CGRect, occludedBy occluders: [CGRect]) -> [CGRect] {
        occluders.reduce([frame]) { parts, occluder in
            parts.flatMap { part -> [CGRect] in
                let overlap = part.intersection(occluder)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [part] }
                return [CGRect(x: part.minX, y: part.minY, width: part.width, height: overlap.minY - part.minY),
                    CGRect(x: part.minX, y: overlap.maxY, width: part.width, height: part.maxY - overlap.maxY),
                    CGRect(x: part.minX, y: overlap.minY, width: overlap.minX - part.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: part.maxX - overlap.maxX, height: overlap.height)]
                    .filter { $0.width > 0 && $0.height > 0 }
            }
        }
    }

    /// A missing frozen window must not silently fall back to a later frame.
    static func resolve(id: CGWindowID, snapshots: [CGWindowID: Self]?,
                        live: () async throws -> Self) async throws -> Self {
        if let snapshots {
            guard let snapshot = snapshots[id] else { throw MacScreenshotError.noWindow }
            return snapshot
        }
        return try await live()
    }
}

@MainActor
enum MacScreenshotPresentation {
    /// Transparent AppKit windows have backing layers even when wantsLayer is
    /// false. display() schedules those layers but may leave them unpainted
    /// until the next transaction, after the window has already been ordered.
    static func prepare(_ view: NSView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layoutSubtreeIfNeeded()
        view.display()
        displayLayers(view.layer)
        CATransaction.commit()
        CATransaction.flush()
    }

    private static func displayLayers(_ layer: CALayer?) {
        guard let layer else { return }
        layer.displayIfNeeded()
        for child in layer.sublayers ?? [] { displayLayers(child) }
    }
}

struct MacScreenshotSource {
    let name: String
    let bundleID: String?

    static let desktop = MacScreenshotSource(name: "桌面", bundleID: nil)
}

enum MacScreenshotError: LocalizedError, Equatable {
    case cancelled, permissionRequired, noDisplay, noWindow, noImage, contentUnavailable, tooLarge
    case windowNotShared(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "已取消截图。"
        case .permissionRequired: "需要允许 ClipHoook 录制屏幕，授权后请再试一次。"
        case .noDisplay: "找不到可截取的屏幕。"
        case .noWindow: "没有找到可截取的窗口。"
        case .noImage: "系统没有返回截图，请重试。"
        case .contentUnavailable: "所选窗口或区域没有返回可见画面。该应用可能禁止其他应用截取；可用它自带的截图功能后再复制。"
        case .tooLarge: "截图超过当前单张图片的存储上限，请缩小区域后重试。"
        case .windowNotShared(let name): "“\(name)”没有向系统共享窗口画面，截图会缺少这个窗口。请用该应用自带截图，再复制到 ClipHoook。"
        }
    }
}

enum MacScreenshotGeometry {
    /// AppKit uses a bottom-left origin; ScreenCaptureKit's display-space
    /// rectangle uses a top-left origin. Both use screen points.
    static func displayRect(for appKitRect: CGRect, mainScreenTop: CGFloat) -> CGRect {
        CGRect(x: appKitRect.minX, y: mainScreenTop - appKitRect.maxY,
               width: appKitRect.width, height: appKitRect.height)
    }

    static func appKitRect(for displayRect: CGRect, mainScreenTop: CGFloat) -> CGRect {
        CGRect(x: displayRect.minX, y: mainScreenTop - displayRect.maxY,
               width: displayRect.width, height: displayRect.height)
    }

    static func shadowedWindowFrame(image: CGImage, window: CGRect, scale: CGFloat) -> CGRect {
        let width = image.width
        let height = image.height
        let extraX = max(0, CGFloat(width) / scale - window.width)
        let extraY = max(0, CGFloat(height) / scale - window.height)
        guard extraX > 0 || extraY > 0 else { return window }

        // Native shadows extend farther below the window. Use the opaque
        // window body to locate it within the bitmap, with a centered fallback
        // for axes where the window is too translucent to infer its bounds.
        var left = extraX / 2
        var top = extraY / 2
        if let mask = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), let data = mask.data {
            mask.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            let stride = mask.bytesPerRow
            var x0 = width
            var x1 = -1
            var y0 = height
            var y1 = -1
            for y in 0..<height {
                let row = pixels + y * stride
                var first = 0
                while first < width && row[first * 4 + 3] < 248 { first += 1 }
                guard first < width else { continue }
                var last = width - 1
                while row[last * 4 + 3] < 248 { last -= 1 }
                x0 = min(x0, first)
                x1 = max(x1, last)
                y0 = min(y0, y)
                y1 = y
            }
            if x1 >= x0, abs(CGFloat(x1 - x0 + 1) / scale - window.width) <= 2 {
                left = min(extraX, CGFloat(x0) / scale)
            }
            if y1 >= y0, abs(CGFloat(y1 - y0 + 1) / scale - window.height) <= 2 {
                top = min(extraY, CGFloat(y0) / scale)
            }
        }
        return CGRect(x: window.minX - left, y: window.minY - (extraY - top),
                      width: window.width + extraX, height: window.height + extraY)
    }

    static func toolbarFrame(near selection: CGRect, in safeArea: CGRect,
                             size: CGSize, gap: CGFloat) -> CGRect {
        let x = min(safeArea.maxX - size.width, max(safeArea.minX, selection.midX - size.width / 2))
        let below = selection.minY - size.height - gap
        let above = selection.maxY + gap
        let y: CGFloat
        if below >= safeArea.minY {
            y = min(below, safeArea.maxY - size.height)
        } else if above + size.height <= safeArea.maxY {
            y = max(above, safeArea.minY)
        } else {
            y = safeArea.minY
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Crop a native display image on pixel boundaries. Capturing an already
    /// cropped sourceRect lets ScreenCaptureKit resample the text before the
    /// annotation canvas ever sees it.
    static func pixelCropRect(_ rect: CGRect, imageSize: CGSize,
                              displaySize: CGSize) -> CGRect {
        let scaleX = imageSize.width / displaySize.width
        let scaleY = imageSize.height / displaySize.height
        let x0 = max(0, floor(rect.minX * scaleX))
        let y0 = max(0, floor(rect.minY * scaleY))
        let x1 = min(imageSize.width, ceil(rect.maxX * scaleX))
        let y1 = min(imageSize.height, ceil(rect.maxY * scaleY))
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0),
                      height: max(0, y1 - y0))
    }
}

/// The screenshot selection reticle is different from AppKit's plain crosshair.
/// Keep its hotspot in the center; the separate pixel loupe and its hints
/// belong to the selector, so neither becomes part of the captured image.
@MainActor
private enum MacScreenshotSelectionCursor {
    static let cursor: NSCursor = {
        let size = CGSize(width: 36, height: 36)
        let center = CGPoint(x: 18, y: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: CGRect(x: 9, y: 9, width: 18, height: 18))
            NSColor(calibratedWhite: 0.65, alpha: 0.30).setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            circle.lineWidth = 2.5
            circle.stroke()
            NSColor(calibratedWhite: 0.45, alpha: 0.85).setStroke()
            circle.lineWidth = 1
            circle.stroke()

            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: 2, y: center.y))
            cross.line(to: CGPoint(x: 34, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: 2))
            cross.line(to: CGPoint(x: center.x, y: 34))
            NSColor.white.withAlphaComponent(0.90).setStroke()
            cross.lineWidth = 2.5
            cross.stroke()
            NSColor(calibratedWhite: 0.20, alpha: 0.95).setStroke()
            cross.lineWidth = 1
            cross.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }()
}

struct MacScreenshotCursorReadout: Equatable {
    let horizontal: Int
    let vertical: Int

    var text: String { "\(horizontal)\n\(vertical)" }

    static func position(_ point: CGPoint, in bounds: CGRect) -> Self {
        Self(horizontal: Int(max(0, min(bounds.width, point.x - bounds.minX)).rounded()),
             vertical: Int(max(0, min(bounds.height, bounds.maxY - point.y)).rounded()))
    }

    static func size(from start: CGPoint, to end: CGPoint) -> Self {
        Self(horizontal: Int(abs(end.x - start.x).rounded()),
             vertical: Int(abs(end.y - start.y).rounded()))
    }
}

struct MacScreenshotDragConstraint {
    private var flags: NSEvent.ModifierFlags = []
    private var horizontal: Bool?
    private var fixedDimension: CGFloat?

    mutating func reset(modifiers: NSEvent.ModifierFlags = []) {
        flags = modifiers
        horizontal = nil
        fixedDimension = nil
    }

    mutating func rect(from start: CGPoint, to point: CGPoint, in bounds: CGRect,
                       modifiers: NSEvent.ModifierFlags) -> CGRect {
        let dx = point.x - start.x
        let dy = point.y - start.y
        if modifiers.contains(.option) {
            flags = modifiers
            let availableX = dx < 0 ? start.x - bounds.minX : bounds.maxX - start.x
            let availableY = dy < 0 ? start.y - bounds.minY : bounds.maxY - start.y
            let side = max(0, min(max(abs(dx), abs(dy)), availableX, availableY))
            return CGRect(x: dx < 0 ? start.x - side : start.x,
                          y: dy < 0 ? start.y - side : start.y,
                          width: side, height: side)
        }
        var end = point
        if modifiers.contains(.shift) {
            if horizontal == nil {
                horizontal = abs(dx) >= abs(dy)
                let opposite = horizontal == true ? abs(dy) : abs(dx)
                fixedDimension = flags.contains(.shift) ? 24 : max(1, opposite)
            }
            if horizontal == true {
                end.y = start.y + (dy < 0 ? -1 : 1) * (fixedDimension ?? 24)
            } else {
                end.x = start.x + (dx < 0 ? -1 : 1) * (fixedDimension ?? 24)
            }
        } else {
            horizontal = nil
            fixedDimension = nil
        }
        flags = modifiers
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
            .intersection(bounds)
    }
}

struct MacScreenshotPixelSample {
    let image: CGImage
    let cropRect: CGRect
    let pixel: CGPoint
    let hex: String

    static func at(_ point: CGPoint, in rect: CGRect, image: CGImage) -> Self? {
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        let x = min(image.width - 1, max(0, Int(floor(
            (point.x - rect.minX) * CGFloat(image.width) / rect.width))))
        let y = min(image.height - 1, max(0, Int(floor(
            (rect.maxY - point.y) * CGFloat(image.height) / rect.height))))
        let crop = CGRect(x: x - 11, y: y - 11, width: 23, height: 23)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let detail = image.cropping(to: crop),
              let colorPixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let buffer = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue), let data = buffer.data else { return nil }
        // NSBitmapImageRep.colorAt can reinterpret a tagged image as calibrated
        // RGB. Convert one pixel explicitly to sRGB before displaying its hex.
        buffer.draw(colorPixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        let alpha = max(1, Int(rgba[3]))
        let r = min(255, Int(rgba[0]) * 255 / alpha)
        let g = min(255, Int(rgba[1]) * 255 / alpha)
        let b = min(255, Int(rgba[2]) * 255 / alpha)
        return Self(image: detail, cropRect: crop, pixel: CGPoint(x: x, y: y),
                    hex: String(format: "#%02X%02X%02X", r, g, b))
    }
}

@MainActor
final class MacScreenshotCapture {
    typealias Completion = @MainActor (Result<MacScreenshotFrame, Error>) -> Void

    enum Selection {
        case region(CGRect)
        case window(CGWindowID, CGRect)
        case screen(CGRect)
    }

    private var overlays: [MacScreenshotOverlayPanel] = []
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var globalPointerMonitor: Any?
    private var captureTask: Task<Void, Never>?
    private var activeCaptureID: UUID?

    var isActive: Bool { !overlays.isEmpty || captureTask != nil }

    /// The recorder only needs a live selection. It must never freeze the
    /// desktop or pass through still-image capture/editor completion paths.
    func selectForRecording(scope: ScreenRecordingScope,
                            completion: @escaping @MainActor (Result<Selection, Error>) -> Void) {
        guard !isActive else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            completion(.failure(ScreenRecordingError.permissionRequired)); return
        }
        if scope == .screen {
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.screens.first else {
                completion(.failure(MacScreenshotError.noDisplay)); return
            }
            completion(.success(.screen(screen.frame)))
            return
        }
        showOverlay(frozenDisplays: [:],
            hints: ("选择录制窗口或拖选区域 · Esc 取消", "正在准备录屏"),
            completion: { result in
                if case .failure(let error) = result { completion(.failure(error)) }
            }, selectionOnly: { [weak self] selection in
                self?.dismissOverlay()
                completion(.success(selection))
            })
    }

    func cancelRecordingSelection() {
        activeCaptureID = nil
        captureTask?.cancel()
        captureTask = nil
        dismissOverlay()
    }

    /// Resolve the visible window under the selection while excluding only
    /// our screenshot overlay. This lets a visible ClipHoook shelf be reported
    /// as the source when it is part of the captured image.
    static func sourceApp(for rect: CGRect,
                          excludingWindowID: CGWindowID? = nil) -> MacScreenshotSource {
        guard let mainScreenTop = NSScreen.screens.first?.frame.maxY else { return .desktop }
        let center = CGPoint(x: rect.midX, y: mainScreenTop - rect.midY)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        for item in windows {
            guard let pid = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let number = item[kCGWindowNumber as String] as? NSNumber,
                  number.uint32Value != excludingWindowID,
                  let layer = item[kCGWindowLayer as String] as? NSNumber,
                  (pid.int32Value == ownPID || layer.intValue == 0),
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.contains(center) else { continue }
            let app = NSRunningApplication(processIdentifier: pid.int32Value)
            let name = app?.localizedName
                ?? item[kCGWindowOwnerName as String] as? String
                ?? "桌面"
            return MacScreenshotSource(name: name, bundleID: app?.bundleIdentifier)
        }
        return .desktop
    }

    private static func sourceApp(forWindowID id: CGWindowID) -> MacScreenshotSource {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        guard let item = windows.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
        }), let pid = item[kCGWindowOwnerPID as String] as? NSNumber else {
            return .desktop
        }
        let app = NSRunningApplication(processIdentifier: pid.int32Value)
        return MacScreenshotSource(
            name: app?.localizedName
                ?? (item[kCGWindowOwnerName as String] as? String) ?? "桌面",
            bundleID: app?.bundleIdentifier
        )
    }

    func begin(_ mode: MacScreenshotMode, freezeDesktop: Bool,
               selectionHints: (selection: String, preparing: String)? = nil,
               completion: @escaping Completion) {
        guard !isActive else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            completion(.failure(MacScreenshotError.permissionRequired))
            return
        }

        switch mode {
        case .region:
            if freezeDesktop {
                let preparationID = UUID()
                activeCaptureID = preparationID
                captureTask = Task { [weak self] in
                    do {
                        async let displays = Self.captureFrozenDisplays()
                        async let windows = Self.captureFrozenWindows()
                        let (frozenDisplays, preparedWindows) = try await (displays, windows)
                        let frozenWindows = await Task.detached(priority: .userInitiated) {
                            preparedWindows.snapshots.mapValues { $0.matching(frozenDisplays) }
                        }.value
                        try Task.checkCancellation()
                        guard let self, self.activeCaptureID == preparationID else { return }
                        self.captureTask = nil
                        self.activeCaptureID = nil
                        self.showOverlay(frozenDisplays: frozenDisplays, frozenWindows: frozenWindows,
                                         windowCandidates: preparedWindows.candidates,
                                         hints: selectionHints,
                                         completion: completion)
                    } catch {
                        guard let self, self.activeCaptureID == preparationID else { return }
                        self.captureTask = nil
                        self.activeCaptureID = nil
                        completion(.failure(error))
                    }
                }
            } else {
                showOverlay(frozenDisplays: [:], hints: selectionHints, completion: completion)
            }
        case .long:
            showOverlay(frozenDisplays: [:],
                        hints: ("拖选要滚动的内容区域 · Esc 取消", "正在准备长截图 · Esc 取消"),
                        allowsWindowSelection: false, completion: completion)
        case .screen:
            guard let screen = NSScreen.screens.first(where: {
                $0.frame.contains(NSEvent.mouseLocation)
            }) ?? NSScreen.screens.first,
                  let mainScreenTop = NSScreen.screens.first?.frame.maxY else {
                completion(.failure(MacScreenshotError.noDisplay))
                return
            }
            capture(.screen(screen.frame), selectionPanel: nil,
                    freezeDesktop: freezeDesktop,
                    mainScreenTop: mainScreenTop,
                    completion: completion)
        }
    }

    private static func captureFrozenDisplays() async throws
        -> [CGDirectDisplayID: MacScreenshotFrozenDisplay] {
        guard let mainScreenTop = NSScreen.screens.first?.frame.maxY else {
            throw MacScreenshotError.noDisplay
        }
        // A protected window is absent from the system's captured image.
        // Keep that display live instead of visually replacing the window
        // with whatever happens to be behind it when the overlay appears.
        let eligibleScreens = NSScreen.screens.filter { screen in
            unsharedWindowName(in: .screen(screen.frame),
                               mainScreenTop: mainScreenTop) == nil
        }
        guard !eligibleScreens.isEmpty else { return [:] }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        var targets: [(id: CGDirectDisplayID, frame: CGRect,
                      scale: CGFloat, display: SCDisplay)] = []
        for screen in eligibleScreens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber,
                  let display = content.displays.first(where: {
                      $0.displayID == number.uint32Value
                  }) else { throw MacScreenshotError.noDisplay }
            targets.append((number.uint32Value, screen.frame,
                            screen.backingScaleFactor, display))
        }
        return try await withThrowingTaskGroup(
            of: (CGDirectDisplayID, MacScreenshotFrozenDisplay).self
        ) { group in
            for target in targets {
                group.addTask {
                    let image: CGImage
                    if #available(macOS 15.2, *) {
                        // Capture the native desktop before any selection UI
                        // exists. A filtered stream with a requested output
                        // size can re-render/rescale already rasterized text.
                        image = try await captureRegion(MacScreenshotGeometry.displayRect(
                            for: target.frame, mainScreenTop: mainScreenTop))
                    } else {
                        let filter = SCContentFilter(display: target.display,
                                                     excludingWindows: [])
                        let configuration = SCStreamConfiguration()
                        let pixelScale = max(target.scale, CGFloat(filter.pointPixelScale))
                        configuration.captureResolution = .best
                        configuration.width = max(1, Int(ceil(target.display.frame.width * pixelScale)))
                        configuration.height = max(1, Int(ceil(target.display.frame.height * pixelScale)))
                        configuration.showsCursor = false
                        image = try await captureFiltered(filter, configuration: configuration)
                    }
                    try Task.checkCancellation()
                    return (target.id, MacScreenshotFrozenDisplay(
                        screenFrame: target.frame, image: image
                    ))
                }
            }
            var result: [CGDirectDisplayID: MacScreenshotFrozenDisplay] = [:]
            for try await (id, frozen) in group { result[id] = frozen }
            return result
        }
    }

    private static func captureFrozenWindows() async throws
        -> (candidates: [MacScreenshotWindowCandidate], snapshots: [CGWindowID: MacScreenshotFrozenWindow]) {
        guard let top = NSScreen.screens.first?.frame.maxY else { throw MacScreenshotError.noDisplay }
        // Fix both lists to the same instant, before any asynchronous capture
        // or selector panel can change the live window ordering and IDs.
        let ordered = MacScreenshotWindowCandidate.windowInfo()
        let candidates = MacScreenshotWindowCandidate.selectable(from: ordered,
            excludingPID: ProcessInfo.processInfo.processIdentifier,
            includingWindowIDs: MacScreenshotWindowCandidate.capturableAppWindowIDs)
        let reachable = MacScreenshotWindowCandidate.reachable(in: candidates)
        // CGWindowList already establishes visibility. Match its window IDs
        // directly instead of filtering a second, later visibility snapshot.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let screens = NSScreen.screens.map(\.frame)
        let includeShadow = ScreenshotWindowShadowPreference.isEnabled()
        let orderedFrames: [(CGWindowID, CGRect)] = ordered.compactMap { item in
            guard let id = item[kCGWindowNumber as String] as? NSNumber,
                  (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (id.uint32Value, MacScreenshotGeometry.appKitRect(for: frame, mainScreenTop: top))
        }
        let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let windows = reachable.compactMap { candidate -> (window: SCWindow, frame: CGRect)? in
            let frame = MacScreenshotGeometry.appKitRect(for: candidate.hitFrame, mainScreenTop: top)
            guard screens.contains(where: { $0.intersects(frame) }),
                  let window = windowsByID[candidate.id] else { return nil }
            return (window, frame)
        }
        let visibleByID = Dictionary(uniqueKeysWithValues: windows.map { target in
            let occluders = orderedFrames.prefix { $0.0 != target.window.windowID }.map(\.1)
            return (target.window.windowID, MacScreenshotFrozenWindow.visibleParts(of: target.frame, occludedBy: occluders))
        })
        // Capture before any selector is shown. Reuse the same isolated window
        // bitmap after a click, including occluded content and optional shadow.
        // Bound in-flight requests so a desktop with many windows cannot start
        // an unbounded batch of ScreenCaptureKit operations.
        let snapshots = try await withThrowingTaskGroup(of: (CGWindowID, MacScreenshotFrozenWindow)?.self) { group in
            var next = windows.makeIterator()
            func enqueue(_ target: (window: SCWindow, frame: CGRect)) {
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let snapshot = try await captureWindow(target.window, frame: target.frame, includeShadow: includeShadow)
                        return (target.window.windowID, MacScreenshotFrozenWindow(image: snapshot.image,
                            frame: snapshot.frame, visibleRects: visibleByID[target.window.windowID] ?? []))
                    } catch is CancellationError { throw CancellationError() }
                    catch { return nil } // Selecting an unavailable snapshot reports an error; never recapture live.
                }
            }
            for _ in 0..<3 { if let window = next.next() { enqueue(window) } }
            var result: [CGWindowID: MacScreenshotFrozenWindow] = [:]
            for try await snapshot in group {
                if let (id, value) = snapshot { result[id] = value }
                if let window = next.next() { enqueue(window) }
            }
            return result
        }
        return (candidates, snapshots)
    }

    private func showOverlay(
        frozenDisplays: [CGDirectDisplayID: MacScreenshotFrozenDisplay],
        frozenWindows: [CGWindowID: MacScreenshotFrozenWindow]? = nil,
        windowCandidates: [MacScreenshotWindowCandidate]? = nil,
        hints: (selection: String, preparing: String)?,
        allowsWindowSelection: Bool = true,
        completion: @escaping Completion,
        selectionOnly: ((Selection) -> Void)? = nil
    ) {
        guard let firstScreen = NSScreen.screens.first else {
            completion(.failure(MacScreenshotError.noDisplay))
            return
        }
        let mainScreenTop = firstScreen.frame.maxY
        let pointer = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            // A borderless window spanning separate display Spaces can be
            // clipped to the primary screen. Give each display its own panel.
            let panel = MacScreenshotOverlayPanel(screenFrame: screen.frame, screen: screen)
            let view = MacScreenshotSelectionView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                mainScreenTop: mainScreenTop, hints: hints,
                allowsWindowSelection: allowsWindowSelection,
                candidates: windowCandidates
            )
            let displayID = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value
            let frozenDisplay = displayID.flatMap { frozenDisplays[$0] }
            if let frozenDisplay {
                view.frozenImage = NSImage(cgImage: frozenDisplay.image,
                                           size: screen.frame.size)
                view.previewImage = frozenDisplay.image
                view.previewRect = view.bounds
            }
            view.previewCapture = { [weak panel] localRect in
                guard let panel else { throw MacScreenshotError.cancelled }
                return try await Self.captureRegionExcludingSelector(
                    localRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY),
                    selectorWindowID: CGWindowID(panel.windowNumber))
            }
            view.onCancel = { [weak self] in
                self?.cancelCapture(completion: completion)
            }
            view.onSelect = { [weak self, weak panel, weak view] selection in
                guard let self, let panel, let view else { return }
                view.lockSelection()
                for other in self.overlays where other !== panel { other.orderOut(nil) }
                if let selectionOnly { selectionOnly(selection); return }
                self.capture(selection, selectionPanel: panel,
                             frozenDisplay: frozenDisplay,
                             frozenWindows: frozenWindows,
                             mainScreenTop: mainScreenTop, completion: completion)
            }
            panel.contentView = view
            overlays.append(panel)
            // Prepare the exact full-screen image AND its initial highlight
            // before ordering any display's panel. Showing the frozen desktop
            // with a utility-window animation looks like the desktop zooming.
            view.updateHover(at: pointer)
            panel.prepareForPresentation()
        }
        for panel in overlays { panel.orderFrontRegardless() }
        // Do not activate ClipHoook: the source application stays foreground.
        // The nonactivating selector still needs key focus for AppKit to install
        // its selection cursor on screen, rather than only in our cursor state.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape), self?.overlays.isEmpty == false else { return event }
            self?.cancelCapture(completion: completion)
            return nil
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.overlays.isEmpty else { return }
                self.cancelCapture(completion: completion)
            }
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pointer = NSEvent.mouseLocation
                for panel in self.overlays where panel.isVisible && panel.frame.contains(pointer) {
                    (panel.contentView as? MacScreenshotSelectionView)?.updateHover(at: pointer)
                }
            }
        }
        let keyPanel = overlays.first(where: { $0.frame.contains(pointer) }) ?? overlays.first
        (keyPanel?.contentView as? MacScreenshotSelectionView)?.updateHover(at: pointer)
    }

    private func dismissOverlay() {
        releaseOverlayEvents()
        for panel in overlays { panel.orderOut(nil) }
        overlays.removeAll()
        NSCursor.arrow.set()
    }

    private func releaseOverlayEvents() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
    }

    private func cancelCapture(completion: @escaping Completion) {
        activeCaptureID = nil
        captureTask?.cancel()
        captureTask = nil
        dismissOverlay()
        completion(.failure(MacScreenshotError.cancelled))
    }

    private func capture(_ selection: Selection,
                         selectionPanel: MacScreenshotOverlayPanel?,
                         frozenDisplay: MacScreenshotFrozenDisplay? = nil,
                         frozenWindows: [CGWindowID: MacScreenshotFrozenWindow]? = nil,
                         freezeDesktop: Bool = false,
                         mainScreenTop: CGFloat,
                         completion: @escaping Completion) {
        let captureID = UUID()
        activeCaptureID = captureID
        captureTask = Task { [weak self] in
            do {
                if let name = Self.unsharedWindowName(in: selection,
                                                      mainScreenTop: mainScreenTop) {
                    throw MacScreenshotError.windowNotShared(name)
                }
                let image: CGImage
                let sourceFrame: CGRect
                switch selection {
                case .region(let appKitRect):
                    if let frozenDisplay {
                        let cropped = try frozenDisplay.crop(appKitRect)
                        sourceFrame = cropped.frame
                        image = cropped.image
                    } else if let overlayWindowID = selectionPanel?.windowNumber {
                        sourceFrame = appKitRect
                        image = try await Self.captureRegionExcludingSelector(
                            appKitRect, selectorWindowID: CGWindowID(overlayWindowID)
                        )
                    } else {
                        sourceFrame = appKitRect
                        let rect = MacScreenshotGeometry.displayRect(
                            for: appKitRect, mainScreenTop: mainScreenTop
                        )
                        image = try await Self.captureRegion(rect)
                    }
                case .window(let windowID, let appKitRect):
                    let captured = try await MacScreenshotFrozenWindow.resolve(id: windowID, snapshots: frozenWindows) {
                        let live = try await Self.captureWindow(id: windowID, frame: appKitRect,
                            includeShadow: ScreenshotWindowShadowPreference.isEnabled())
                        return MacScreenshotFrozenWindow(image: live.image, frame: live.frame)
                    }
                    sourceFrame = captured.frame
                    image = captured.image
                case .screen(let appKitRect):
                    sourceFrame = appKitRect
                    let rect = MacScreenshotGeometry.displayRect(
                        for: appKitRect, mainScreenTop: mainScreenTop
                    )
                    image = try await Self.captureRegion(rect)
                }
                try Task.checkCancellation()
                guard Self.hasVisiblePixels(image) else {
                    throw MacScreenshotError.contentUnavailable
                }
                guard let self, self.activeCaptureID == captureID else { return }
                self.captureTask = nil
                self.activeCaptureID = nil
                let finalFrozenDisplay = {
                    if case .window = selection { return nil as MacScreenshotFrozenDisplay? }
                    return frozenDisplay ?? (freezeDesktop ? MacScreenshotFrozenDisplay(
                        screenFrame: sourceFrame, image: image
                    ) : nil)
                }()
                let source: MacScreenshotSource
                let isWindowCapture: Bool
                if case .window(let windowID, _) = selection {
                    isWindowCapture = true
                    source = Self.sourceApp(forWindowID: windowID)
                } else if selectionPanel == nil {
                    isWindowCapture = false
                    source = .desktop
                } else {
                    isWindowCapture = false
                    source = Self.sourceApp(for: sourceFrame,
                                            excludingWindowID: selectionPanel.map {
                                                CGWindowID($0.windowNumber)
                                            })
                }
                // The editor takes over this same panel, so the compositor
                // never removes one full-screen window to reveal another.
                NSCursor.arrow.set()
                completion(.success(MacScreenshotFrame(image: image,
                                                      sourceFrame: sourceFrame,
                                                      source: source,
                                                      selectionPanel: selectionPanel,
                                                      isWindowCapture: isWindowCapture,
                                                      frozenDisplay: finalFrozenDisplay)))
                self.releaseOverlayEvents()
                self.overlays.removeAll()
                if selectionPanel?.contentView is MacScreenshotSelectionView {
                    selectionPanel?.orderOut(nil)
                }
            } catch {
                guard let self, self.activeCaptureID == captureID else { return }
                self.captureTask = nil
                self.activeCaptureID = nil
                self.dismissOverlay()
                completion(.failure(error))
            }
        }
    }

    /// Some apps mark their window as unavailable to screen capture. A display
    /// capture can still return valid pixels from the windows *behind* it, so
    /// checking only for a transparent image would silently save wrong content.
    static func unsharedWindowName(in selection: Selection,
                                           mainScreenTop: CGFloat) -> String? {
        let selectedWindowID: CGWindowID?
        let selectedRect: CGRect
        let isWholeScreen: Bool
        switch selection {
        case .region(let rect):
            selectedWindowID = nil
            selectedRect = MacScreenshotGeometry.displayRect(
                for: rect, mainScreenTop: mainScreenTop
            )
            isWholeScreen = false
        case .window(let id, let rect):
            selectedWindowID = id
            selectedRect = MacScreenshotGeometry.displayRect(
                for: rect, mainScreenTop: mainScreenTop
            )
            isWholeScreen = false
        case .screen(let rect):
            selectedWindowID = nil
            selectedRect = MacScreenshotGeometry.displayRect(
                for: rect, mainScreenTop: mainScreenTop
            )
            isWholeScreen = true
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windowItems = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        struct VisibleWindow {
            let number: CGWindowID
            let pid: pid_t
            let frame: CGRect
            let isShared: Bool
            let ownerName: String?
        }
        // Window Services returns frontmost windows first. Only a protected
        // window actually visible through the selection should stop an area
        // capture; one hidden behind another app must not cancel it.
        let windows: [VisibleWindow] = windowItems.compactMap { item in
            guard let number = item[kCGWindowNumber as String] as? NSNumber,
                  let pid = item[kCGWindowOwnerPID as String] as? NSNumber,
                  pid.int32Value != ownPID,
                  let layer = item[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let alpha = item[kCGWindowAlpha as String] as? NSNumber,
                  alpha.doubleValue > 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let sharing = item[kCGWindowSharingState as String] as? NSNumber
            return VisibleWindow(
                number: number.uint32Value, pid: pid.int32Value, frame: frame,
                isShared: sharing?.uint32Value != CGWindowSharingType.none.rawValue,
                ownerName: item[kCGWindowOwnerName as String] as? String
            )
        }
        for (index, item) in windows.enumerated() where !item.isShared {
            if let selectedWindowID {
                guard item.number == selectedWindowID else { continue }
            } else {
                let overlap = selectedRect.intersection(item.frame)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
                let samplesPerAxis = 7
                let sampleTotal = samplesPerAxis * samplesPerAxis
                let higherWindows = windows.prefix(index)
                var visibleSamples = 0
                for row in 0..<samplesPerAxis {
                    for column in 0..<samplesPerAxis {
                        let point = CGPoint(
                            x: overlap.minX + (CGFloat(column) + 0.5)
                                * overlap.width / CGFloat(samplesPerAxis),
                            y: overlap.minY + (CGFloat(row) + 0.5)
                                * overlap.height / CGFloat(samplesPerAxis)
                        )
                        if !higherWindows.contains(where: { $0.frame.contains(point) }) {
                            visibleSamples += 1
                        }
                    }
                }
                let visibleArea = overlap.width * overlap.height
                    * CGFloat(visibleSamples) / CGFloat(sampleTotal)
                let selectedArea = selectedRect.width * selectedRect.height
                guard isWholeScreen ? visibleArea >= 5_000
                    : visibleArea >= selectedArea * 0.5 else { continue }
            }
            let application = NSRunningApplication(processIdentifier: item.pid)
            return application?.localizedName
                ?? item.ownerName
                ?? "这个应用"
        }
        return nil
    }

    /// Prepare a single-display filter once for a scrolling session. The
    /// utility overlays are excluded, and the source application stays live.
    static func longScreenshotSampler(for rect: CGRect, excluding windowIDs: Set<CGWindowID>) async throws
        -> @MainActor () async throws -> CGImage {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(rect) }),
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { throw MacScreenshotError.noDisplay }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw MacScreenshotError.noDisplay
        }
        let windows = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter: SCContentFilter
        if windows.count == windowIDs.count {
            filter = SCContentFilter(display: display, excludingWindows: windows)
        } else if let owner = content.applications.first(where: {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }) {
            filter = SCContentFilter(display: display, excludingApplications: [owner], exceptingWindows: [])
        } else {
            throw MacScreenshotError.noImage
        }
        let scale = max(screen.backingScaleFactor, CGFloat(filter.pointPixelScale))
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.width = max(1, Int(ceil(display.frame.width * scale)))
        config.height = max(1, Int(ceil(display.frame.height * scale)))
        config.showsCursor = false
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        let size = display.frame.size
        let originalFrame = screen.frame
        let originalScale = screen.backingScaleFactor
        return {
            guard NSScreen.screens.contains(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
                    && $0.frame == originalFrame && $0.backingScaleFactor == originalScale
            }), let mainScreenTop = NSScreen.screens.first?.frame.maxY else {
                throw MacScreenshotError.noDisplay
            }
            if let name = unsharedWindowName(in: .region(rect), mainScreenTop: mainScreenTop) {
                throw MacScreenshotError.windowNotShared(name)
            }
            let full = try await captureFiltered(filter, configuration: config)
            try Task.checkCancellation()
            let crop = MacScreenshotGeometry.pixelCropRect(local,
                imageSize: CGSize(width: full.width, height: full.height), displaySize: size)
            guard let image = full.cropping(to: crop) else { throw MacScreenshotError.noImage }
            return image
        }
    }

    static func captureRegionExcludingSelector(
        _ rect: CGRect, selectorWindowID: CGWindowID
    ) async throws -> CGImage {
        if let mainScreenTop = NSScreen.screens.first?.frame.maxY,
           let name = unsharedWindowName(in: .region(rect),
                                         mainScreenTop: mainScreenTop) {
            throw MacScreenshotError.windowNotShared(name)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let processID = ProcessInfo.processInfo.processIdentifier
        let selector = content.windows.first { $0.windowID == selectorWindowID }
        let owningApp = content.applications.first { $0.processID == processID }
        guard selector != nil || owningApp != nil else {
            throw MacScreenshotError.noImage
        }

        let segments: [(CGRect, SCDisplay, CGRect, CGFloat)] = NSScreen.screens.compactMap {
            screen -> (CGRect, SCDisplay, CGRect, CGFloat)? in
            let overlap = rect.intersection(screen.frame)
            guard overlap.width >= 1, overlap.height >= 1,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber,
                  let display = content.displays.first(where: {
                      $0.displayID == number.uint32Value
                  }) else { return nil }
            return (
                overlap, display,
                CGRect(x: overlap.minX - screen.frame.minX,
                       y: screen.frame.maxY - overlap.maxY,
                       width: overlap.width, height: overlap.height),
                screen.backingScaleFactor
            )
        }
        guard !segments.isEmpty else { throw MacScreenshotError.noDisplay }

        var captured: [(CGRect, CGImage)] = []
        for (overlap, display, localRect, screenScale) in segments {
            let filter: SCContentFilter
            if let selector {
                filter = SCContentFilter(display: display, excludingWindows: [selector])
            } else if let owningApp {
                let otherOwnWindows = content.windows.filter {
                    $0.owningApplication?.processID == processID
                        && $0.windowID != selectorWindowID
                }
                filter = SCContentFilter(display: display,
                                         excludingApplications: [owningApp],
                                         exceptingWindows: otherOwnWindows)
            } else {
                throw MacScreenshotError.noImage
            }
            let config = SCStreamConfiguration()
            // Ask ScreenCaptureKit for the entire display at its native
            // resolution, then crop the returned CGImage without drawing it
            // into another bitmap. A sourceRect-sized capture can be sampled
            // at nominal resolution even when width/height request Retina.
            let pixelScale = max(screenScale, CGFloat(filter.pointPixelScale))
            config.captureResolution = .best
            config.width = max(1, Int(ceil(display.frame.width * pixelScale)))
            config.height = max(1, Int(ceil(display.frame.height * pixelScale)))
            config.showsCursor = false
            let fullImage = try await captureFiltered(filter, configuration: config)
            try Task.checkCancellation()
            let cropRect = MacScreenshotGeometry.pixelCropRect(
                localRect,
                imageSize: CGSize(width: fullImage.width, height: fullImage.height),
                displaySize: display.frame.size
            )
            guard cropRect.width >= 1, cropRect.height >= 1,
                  let image = fullImage.cropping(to: cropRect) else {
                throw MacScreenshotError.noImage
            }
            captured.append((overlap, image))
        }
        if captured.count == 1, let image = captured.first?.1 {
            // Avoid a second bitmap draw and rescale on the common path.
            return image
        }

        let scale = segments.map(\.3).max() ?? 1
        guard let context = CGContext(
            data: nil, width: max(1, Int(ceil(rect.width * scale))),
            height: max(1, Int(ceil(rect.height * scale))),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MacScreenshotError.noImage }
        for (overlap, image) in captured {
            context.draw(image, in: CGRect(
                x: (overlap.minX - rect.minX) * scale,
                y: (overlap.minY - rect.minY) * scale,
                width: overlap.width * scale, height: overlap.height * scale
            ))
        }
        guard let image = context.makeImage() else { throw MacScreenshotError.noImage }
        return image
    }

    nonisolated private static func captureFiltered(
        _ filter: SCContentFilter, configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            ) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? MacScreenshotError.noImage) }
            }
        }
    }

    private static func captureRegion(_ rect: CGRect) async throws -> CGImage {
        guard #available(macOS 15.2, *) else {
            guard let top = NSScreen.screens.first?.frame.maxY else { throw MacScreenshotError.noDisplay }
            let appKitRect = MacScreenshotGeometry.appKitRect(for: rect, mainScreenTop: top)
            let sampler = try await longScreenshotSampler(for: appKitRect, excluding: [])
            return try await sampler()
        }
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? MacScreenshotError.noImage) }
            }
        }
    }

    private static func captureWindow(id: CGWindowID, frame: CGRect,
                                      includeShadow: Bool) async throws
        -> (image: CGImage, frame: CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: {
            $0.windowID == id && $0.isOnScreen && $0.windowLayer == 0
        }) else { throw MacScreenshotError.noWindow }
        return try await captureWindow(window, frame: frame, includeShadow: includeShadow)
    }

    private static func captureWindow(_ window: SCWindow, frame: CGRect,
                                      includeShadow: Bool) async throws -> (image: CGImage, frame: CGRect) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image: CGImage
        if #available(macOS 26.0, *) {
            let configuration = SCScreenshotConfiguration()
            configuration.ignoreShadows = !includeShadow
            configuration.includeChildWindows = false
            configuration.showsCursor = false
            image = try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureScreenshot(
                    contentFilter: filter, configuration: configuration
                ) { output, error in
                    if let image = output?.sdrImage { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? MacScreenshotError.noImage) }
                }
            }
        } else {
            let configuration = SCStreamConfiguration()
            configuration.captureResolution = .best
            configuration.ignoreShadowsSingleWindow = !includeShadow
            if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
            configuration.showsCursor = false
            let scale = max(1, CGFloat(filter.pointPixelScale))
            configuration.width = max(1, Int(ceil(frame.width * scale)))
            configuration.height = max(1, Int(ceil(frame.height * scale)))
            image = try await captureFiltered(filter, configuration: configuration)
        }
        guard includeShadow else { return (image, frame) }
        let pixelScale = max(1, CGFloat(filter.pointPixelScale))
        let alignedFrame = await Task.detached(priority: .userInitiated) {
            MacScreenshotGeometry.shadowedWindowFrame(image: image, window: frame, scale: pixelScale)
        }.value
        return (image, alignedFrame)
    }

    /// A protected window may yield a valid CGImage whose every pixel is
    /// transparent. Do not send that image into the editor as a blank card.
    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        let side = 32
        let bytesPerRow = side * 4
        var bytes = [UInt8](repeating: 0, count: side * bytesPerRow)
        guard let context = CGContext(
            data: &bytes, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 0 }
    }

    static func encode(_ image: CGImage, maximumBytes: Int) throws -> MacScreenshotImage {
        if let png = NSBitmapImageRep(cgImage: image).representation(
            using: .png, properties: [:]
        ), png.count <= maximumBytes {
            return MacScreenshotImage(data: png, type: UTType.png.identifier)
        }
        // A large photographic desktop may exceed the existing 15 MB image
        // limit. Keep full pixel dimensions and try a high-quality HEIC before
        // reporting the limit; never silently omit the card.
        let heic = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(
            heic, UTType.heic.identifier as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: 0.95
            ] as CFDictionary)
            if CGImageDestinationFinalize(destination), heic.length <= maximumBytes {
                return MacScreenshotImage(data: heic as Data, type: UTType.heic.identifier)
            }
        }
        throw MacScreenshotError.tooLarge
    }
}

private final class MacScreenshotOverlayPanel: NSPanel {
    convenience init(screenFrame: CGRect, screen: NSScreen? = nil) {
        // This initializer takes coordinates relative to the supplied screen.
        // Select that screen before painting so a 1x external display doesn't
        // inherit the main display's 2x backing scale for its first frame.
        let contentRect = screen.map {
            screenFrame.offsetBy(dx: -$0.frame.minX, dy: -$0.frame.minY)
        } ?? screenFrame
        self.init(contentRect: contentRect,
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false, screen: screen)
        animationBehavior = .none
        worksWhenModal = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
    }

    /// displayIfNeeded() deliberately defers drawing a hidden window. Force
    /// the first frame into its backing store while it is still off screen.
    func prepareForPresentation() {
        if let contentView { MacScreenshotPresentation.prepare(contentView) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class MacScreenshotSelectionView: NSView {
    private let windows: [MacScreenshotWindowCandidate]
    private let mainScreenTop: CGFloat
    private let selectionHints: (selection: String, preparing: String)
    private var startPoint: CGPoint?
    private var dragConstraint = MacScreenshotDragConstraint()
    private var selectedRect: CGRect?
    private var hoveredWindow: MacScreenshotWindowCandidate?
    private var pressedWindow: MacScreenshotWindowCandidate?
    private var cursorPoint: CGPoint? { didSet { updateLoupe() } }
    private var selectionLocked = false { didSet { updateLoupe() } }
    private var cursorTrackingArea: NSTrackingArea?
    var frozenImage: NSImage? { didSet { needsDisplay = true } }
    private let loupe = MacScreenshotLoupeView(frame: .zero)
    var previewImage: CGImage? { didSet { updateLoupe() } }
    var previewRect: CGRect? { didSet { updateLoupe() } }
    var previewCapture: ((CGRect) async throws -> CGImage)?
    private var previewTask: Task<Void, Never>?

    var onCancel: (() -> Void)?
    var onSelect: ((MacScreenshotCapture.Selection) -> Void)?

    init(frame: CGRect, mainScreenTop: CGFloat,
         hints: (selection: String, preparing: String)? = nil,
         allowsWindowSelection: Bool = true,
         candidates: [MacScreenshotWindowCandidate]? = nil) {
        self.mainScreenTop = mainScreenTop
        self.selectionHints = hints ?? ("点选窗口 / 拖选区域", "正在准备标注…")
        self.windows = allowsWindowSelection ? (candidates ?? MacScreenshotWindowCandidate.selectable(
            from: MacScreenshotWindowCandidate.windowInfo(),
            excludingPID: ProcessInfo.processInfo.processIdentifier,
            includingWindowIDs: MacScreenshotWindowCandidate.capturableAppWindowIDs)) : []
        super.init(frame: frame)
        loupe.isHidden = true
        addSubview(loupe)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var operationHint: String {
        selectionLocked ? selectionHints.preparing : selectionHints.selection
    }

    func lockSelection() {
        selectionLocked = true
        previewTask?.cancel()
        previewTask = nil
        onSelect = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !selectionLocked { addCursorRect(bounds, cursor: MacScreenshotSelectionCursor.cursor) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved,
                      .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    private func setSelectionCursor() {
        guard !selectionLocked else { return }
        // NSCursor.set() on a non-key panel can update NSCursor.current while
        // the cursor actually displayed by macOS remains the source app's arrow.
        // A nonactivating panel can own key focus without activating ClipHoook.
        // Repeat on display changes, but never bring hidden/handed-off layers back.
        if let window, window.isVisible, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self)
            window.resetCursorRects()
        }
        MacScreenshotSelectionCursor.cursor.set()
    }

    override func cursorUpdate(with event: NSEvent) { setSelectionCursor() }
    override func mouseEntered(with event: NSEvent) { setSelectionCursor() }
    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        previewTask?.cancel()
        previewTask = nil
        needsDisplay = true
    }

    func updateHover(at globalPoint: CGPoint) {
        guard !selectionLocked else { return }
        if window?.frame.contains(globalPoint) == true { setSelectionCursor() }
        cursorPoint = window?.frame.contains(globalPoint) == true
            ? CGPoint(x: globalPoint.x - (window?.frame.minX ?? 0),
                      y: globalPoint.y - (window?.frame.minY ?? 0)) : nil
        let displayPoint = CGPoint(x: globalPoint.x, y: mainScreenTop - globalPoint.y)
        hoveredWindow = windows.first { $0.hitFrame.contains(displayPoint) }
        requestLoupePreview()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard !selectionLocked else { return }
        setSelectionCursor()
        updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        guard !selectionLocked else { return }
        setSelectionCursor()
        if let window { updateHover(at: window.convertPoint(toScreen: event.locationInWindow)) }
        pressedWindow = hoveredWindow
        startPoint = convert(event.locationInWindow, from: nil)
        dragConstraint.reset(modifiers: event.modifierFlags)
        selectedRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !selectionLocked else { return }
        setSelectionCursor()
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        selectedRect = dragConstraint.rect(from: startPoint, to: point, in: bounds,
                                           modifiers: event.modifierFlags)
        requestLoupePreview()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !selectionLocked else { return }
        guard let startPoint else { return }
        self.startPoint = nil
        let point = convert(event.locationInWindow, from: nil)
        // A click is determined by pointer travel, before Shift/Option shape
        // constraints. A still-held shortcut modifier must not turn a click
        // into a narrow, invalid drag that silently does nothing.
        if abs(point.x - startPoint.x) < 5, abs(point.y - startPoint.y) < 5, let pressedWindow {
            self.pressedWindow = nil
            let frame = MacScreenshotGeometry.appKitRect(
                for: pressedWindow.hitFrame, mainScreenTop: mainScreenTop
            )
            onSelect?(.window(pressedWindow.id, frame))
            return
        }
        pressedWindow = nil
        let rect = dragConstraint.rect(from: startPoint, to: point, in: bounds,
                                       modifiers: event.modifierFlags)
        guard rect.width >= 5, rect.height >= 5, let window else {
            selectedRect = nil
            needsDisplay = true
            return
        }
        onSelect?(.region(rect.offsetBy(dx: window.frame.minX,
                                        dy: window.frame.minY)))
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { onCancel?() }
        else if !selectionLocked, event.keyCode == UInt16(kVK_ANSI_C),
                event.modifierFlags.contains(.command), let sample = pixelSample {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sample.hex, forType: .string)
        }
        else { super.keyDown(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if let startPoint, let cursorPoint, !selectionLocked {
            selectedRect = dragConstraint.rect(from: startPoint, to: cursorPoint,
                                               in: bounds, modifiers: event.modifierFlags)
            needsDisplay = true
        }
        super.flagsChanged(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { previewTask?.cancel(); previewTask = nil }
    }

    private var pixelSample: MacScreenshotPixelSample? {
        guard let cursorPoint, let previewImage, let previewRect else { return nil }
        return MacScreenshotPixelSample.at(cursorPoint, in: previewRect, image: previewImage)
    }

    private func requestLoupePreview() {
        guard frozenImage == nil, previewTask == nil, !selectionLocked,
              cursorPoint != nil, window?.isVisible == true, previewCapture != nil else { return }
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self, !self.selectionLocked,
                  let point = self.cursorPoint, let capture = self.previewCapture else { return }
            let rect = CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
                .intersection(self.bounds)
            do {
                let image = try await capture(rect)
                guard !Task.isCancelled, !self.selectionLocked, self.window != nil else { return }
                self.previewImage = image
                self.previewRect = rect
                self.needsDisplay = true
            } catch {
                guard !Task.isCancelled else { return }
                self.previewImage = nil
                self.previewRect = nil
            }
            self.previewTask = nil
            if self.cursorPoint != point { self.requestLoupePreview() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        frozenImage?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        let highlight: CGRect?
        if let selectedRect, selectedRect.width >= 5 || selectedRect.height >= 5 {
            highlight = selectedRect
        } else if let hoveredWindow, let window {
            let global = MacScreenshotGeometry.appKitRect(
                for: hoveredWindow.hitFrame, mainScreenTop: mainScreenTop
            )
            highlight = global.offsetBy(dx: -window.frame.minX,
                                        dy: -window.frame.minY).intersection(bounds)
        } else {
            highlight = nil
        }
        let dim = NSBezierPath(rect: bounds)
        if let highlight, !highlight.isEmpty { dim.appendRect(highlight) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()
        if let highlight, !highlight.isEmpty {
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(roundedRect: highlight, xRadius: 2, yRadius: 2)
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    private func updateLoupe() {
        guard let point = cursorPoint else { loupe.isHidden = true; return }
        let size = MacScreenshotLoupeView.panelSize
        let x = point.x + size.width + 14 < bounds.maxX
            ? point.x + 14 : point.x - size.width - 14
        let y = point.y - size.height - 12 >= bounds.minY
            ? point.y - size.height - 12 : point.y + 12
        loupe.frame = CGRect(x: min(max(8, x), bounds.maxX - size.width - 8),
                             y: min(max(8, y), bounds.maxY - size.height - 8),
                             width: size.width, height: size.height)
        loupe.update(sample: pixelSample, instruction: operationHint)
        loupe.isHidden = false
    }
}

/// A passive native glass HUD. Its content never intercepts selection events
/// or enters captured pixels; the actual pixel sample remains unfiltered.
@MainActor
private final class MacScreenshotLoupeView: NSView {
    static let panelSize = CGSize(width: 168, height: 226)
    private final class ReadableFooter: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            NSColor(white: dark ? 0.26 : 0.99, alpha: 0.80).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
    private let readableFooter = ReadableFooter()
    private let glass: NSView
    private let content: NSView
    private let preview = MacScreenshotLoupePreviewView()
    private let swatch = NSView()
    private let colorValue = NSTextField(labelWithString: "")
    private let instruction = NSTextField(labelWithString: "")
    private let keyboardHint = NSTextField(labelWithString: "Esc 取消 · ⌘C 取色")

    override init(frame: CGRect) {
        let contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content = contentView
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .clear
            effect.cornerRadius = 12
            effect.contentView = contentView
            glass = effect
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            effect.addSubview(contentView)
            glass = effect
        }
        super.init(frame: frame)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        addSubview(glass)
        for view in [preview, readableFooter, swatch, colorValue, instruction, keyboardHint] {
            content.addSubview(view)
        }
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        colorValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        colorValue.textColor = .labelColor
        instruction.font = .systemFont(ofSize: 10)
        instruction.textColor = .labelColor
        keyboardHint.font = .systemFont(ofSize: 9)
        keyboardHint.textColor = .secondaryLabelColor
        for label in [colorValue, instruction, keyboardHint] {
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.helpTag)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let side = bounds.width - 16
        preview.frame = CGRect(x: 8, y: bounds.maxY - 8 - side, width: side, height: side)
        readableFooter.frame = CGRect(x: 8, y: 5, width: bounds.width - 16, height: 57)
        swatch.frame = CGRect(x: 12, y: 47, width: 11, height: 11)
        colorValue.frame = CGRect(x: 29, y: 44, width: bounds.width - 41, height: 16)
        instruction.frame = CGRect(x: 12, y: 25, width: bounds.width - 24, height: 14)
        keyboardHint.frame = CGRect(x: 12, y: 9, width: bounds.width - 24, height: 13)
    }

    func update(sample: MacScreenshotPixelSample?, instruction text: String) {
        preview.sample = sample
        colorValue.stringValue = sample?.hex ?? "—"
        instruction.stringValue = text
        if let hex = sample?.hex, let rgb = UInt32(hex.dropFirst(), radix: 16) {
            swatch.layer?.backgroundColor = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1).cgColor
        } else { swatch.layer?.backgroundColor = NSColor.separatorColor.cgColor }
        setAccessibilityLabel("\(text)，色值 \(sample?.hex ?? "正在读取")。Esc 取消，Command C 复制色值。")
        needsLayout = true
    }
}

@MainActor
private final class MacScreenshotLoupePreviewView: NSView {
    var sample: MacScreenshotPixelSample? { didSet { needsDisplay = true } }
    static var crosshairColor: NSColor { .systemBlue }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        guard let sample else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.interpolationQuality = .none
        let scale: CGFloat = 7
        let crop = sample.cropRect
        let target = CGRect(x: bounds.midX + (crop.minX - sample.pixel.x - 0.5) * scale,
                            y: bounds.midY - (crop.maxY - sample.pixel.y - 0.5) * scale,
                            width: crop.width * scale, height: crop.height * scale)
        context.draw(sample.image, in: target)
        context.setStrokeColor(Self.crosshairColor.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        context.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
        context.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
        context.strokePath()
        context.restoreGState()
    }
}
