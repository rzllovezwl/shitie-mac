import AppKit

@main
struct MacScreenshotGeometrySmoke {
    static func main() async throws {
        func info(_ id: Int, _ frame: CGRect, pid: Int = 7, layer: Int = 0,
                  alpha: Double = 1) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id),
             kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: alpha),
             kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let desktop = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let candidates = MacScreenshotWindowCandidate.selectable(from: [
            info(1, desktop, layer: 1000), // A full-screen auxiliary HUD is not a selectable window.
            info(2, desktop, pid: 99), // Neither is our own transparent selector/panel.
            info(3, desktop, alpha: 0),
            info(4, CGRect(x: 20, y: 20, width: 400, height: 300)),
            info(5, CGRect(x: 40, y: 40, width: 100, height: 100)),
            info(6, CGRect(x: 600, y: 20, width: 300, height: 300))
        ], excludingPID: 99)
        precondition(candidates.map(\.id) == [4, 5, 6],
            "选窗与冻结预取必须共享按前后顺序过滤的窗口列表，忽略辅助层、自身窗口及全透明窗口")
        let editorCandidates = MacScreenshotWindowCandidate.selectable(from: [
            info(10, desktop, pid: 99),
            info(11, desktop, pid: 99, layer: 1000),
            info(12, desktop, pid: 99),
            info(13, desktop, pid: 99, alpha: 0)
        ], excludingPID: 99, includingWindowIDs: [10, 11, 13])
        precondition(editorCandidates.map(\.id) == [10],
            "允许点选标注窗口自身，但不能把选区覆盖层、浮层或透明窗口作为截图目标")
        precondition(MacScreenshotWindowCandidate.reachable(in: candidates).map(\.id) == [4, 6],
            "前方辅助层不能导致可点选窗口漏存快照；真正被另一可选窗口完全挡住的才可跳过")
        let exposed = [MacScreenshotWindowCandidate(id: 8, hitFrame: CGRect(x: 200, y: 0, width: 200, height: 300)),
                       MacScreenshotWindowCandidate(id: 9, hitFrame: CGRect(x: 100, y: 0, width: 200, height: 300))]
        precondition(MacScreenshotWindowCandidate.reachable(in: exposed).count == 2,
            "只露出一部分的下层窗口仍须预取，以便点选时得到完整独立窗口")
        let oldFrame = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        oldFrame.setFillColor(NSColor.red.cgColor)
        oldFrame.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        oldFrame.clear(CGRect(x: 0, y: 0, width: 4, height: 20))
        let frozenWindow = MacScreenshotFrozenWindow(image: oldFrame.makeImage()!, frame: CGRect(x: 10, y: 20, width: 40, height: 20))
        var liveCalls = 0
        let snapshot = try await MacScreenshotFrozenWindow.resolve(id: 42, snapshots: [42: frozenWindow]) {
            liveCalls += 1
            throw MacScreenshotError.noImage
        }
        precondition(liveCalls == 0 && snapshot.image === frozenWindow.image && snapshot.frame == frozenWindow.frame,
            "点击冻结窗口必须复用最初的独立窗口帧，不能重新截取播放中的视频")
        do {
            _ = try await MacScreenshotFrozenWindow.resolve(id: 43, snapshots: [:]) {
                liveCalls += 1
                return frozenWindow
            }
            preconditionFailure("缺失的冻结窗口不可静默换成实时帧")
        } catch MacScreenshotError.noWindow { }
        precondition(liveCalls == 0)
        _ = try await MacScreenshotFrozenWindow.resolve(id: 42, snapshots: nil) {
            liveCalls += 1
            return frozenWindow
        }
        precondition(liveCalls == 1, "关闭冻结后仍使用实时窗口截取")
        let frozenScreen = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        frozenScreen.setFillColor(NSColor.green.cgColor)
        frozenScreen.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        // A different foreground window covers the right half on the desktop.
        frozenScreen.setFillColor(NSColor.blue.cgColor)
        frozenScreen.fill(CGRect(x: 30, y: 20, width: 20, height: 20))
        let visible = MacScreenshotFrozenWindow.visibleParts(of: frozenWindow.frame,
            occludedBy: [CGRect(x: 30, y: 20, width: 20, height: 20)])
        let synchronized = MacScreenshotFrozenWindow(image: frozenWindow.image, frame: frozenWindow.frame,
            visibleRects: visible).matching([1: MacScreenshotFrozenDisplay(
                screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100), image: frozenScreen.makeImage()!)])
        func pixel(_ image: CGImage, x: Int) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image.cropping(to: CGRect(x: x, y: 10, width: 1, height: 1))!,
                in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return rgba
        }
        let left = pixel(synchronized.image, x: 10), right = pixel(synchronized.image, x: 30)
        precondition(left[1] > 240 && left[0] < 10,
            "窗口可见部分应与已冻结屏幕逐像素保持一致，避免窗口快照晚一帧造成跳变")
        precondition(right[0] > 240 && right[2] < 10,
            "被遮挡区域必须保留独立窗口像素，不能把前方蓝色窗口截进来")
        precondition(pixel(synchronized.image, x: 1)[3] == 0,
            "同步冻结像素时不可填平原有窗口透明圆角或阴影边缘")
        let mainTop: CGFloat = 900
        let screenRects = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: -200, width: 1920, height: 1080),
            CGRect(x: -1280, y: 900, width: 1280, height: 800)
        ]
        for rect in screenRects {
            let display = MacScreenshotGeometry.displayRect(
                for: rect, mainScreenTop: mainTop
            )
            let restored = MacScreenshotGeometry.appKitRect(
                for: display, mainScreenTop: mainTop
            )
            precondition(restored == rect, "跨显示器截图坐标转换必须可逆")
        }
        let secondary = MacScreenshotGeometry.displayRect(
            for: screenRects[1], mainScreenTop: mainTop
        )
        precondition(secondary.minX == 1440 && secondary.minY == 20,
                     "右侧显示器的选区应映射到正确的显示坐标")
        let retinaCrop = MacScreenshotGeometry.pixelCropRect(
            CGRect(x: 10.25, y: 20.5, width: 100.25, height: 50),
            imageSize: CGSize(width: 2880, height: 1800),
            displaySize: CGSize(width: 1440, height: 900)
        )
        precondition(retinaCrop == CGRect(x: 20, y: 41, width: 201, height: 100),
                     "Retina 选区应以原生像素裁切，不能缩放截图")
        let readoutBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cursorPosition = MacScreenshotCursorReadout.position(
            CGPoint(x: 69, y: 835), in: readoutBounds)
        precondition(cursorPosition.text == "69\n65", "准星坐标应从当前屏幕左上角起算")
        precondition(MacScreenshotCursorReadout.position(
            CGPoint(x: 79, y: 855), in: readoutBounds.offsetBy(dx: 10, dy: 20))
                     == cursorPosition, "坐标读数不应受到外接屏全局偏移的影响")
        precondition(MacScreenshotCursorReadout.size(
            from: CGPoint(x: 600, y: 500), to: CGPoint(x: 100, y: 300)).text == "500\n200",
                     "反向拖选时也应显示正的选区宽高")
        let preferences = UserDefaults(suiteName: "com.cliphoook.screenshot-freeze-smoke")!
        preferences.removePersistentDomain(forName: "com.cliphoook.screenshot-freeze-smoke")
        precondition(ScreenshotFreezePreference.isEnabled(in: preferences),
                     "截图画面冻结应默认开启")
        preferences.set(false, forKey: ScreenshotFreezePreference.enabledKey)
        precondition(!ScreenshotFreezePreference.isEnabled(in: preferences),
                     "用户应能关闭截图画面冻结")
        precondition(!ScreenshotWindowShadowPreference.isEnabled(in: preferences),
                     "窗口截图阴影应默认关闭")
        preferences.set(true, forKey: ScreenshotWindowShadowPreference.enabledKey)
        precondition(ScreenshotWindowShadowPreference.isEnabled(in: preferences),
                     "用户应能在设置中开启窗口阴影")
        preferences.removePersistentDomain(forName: "com.cliphoook.screenshot-freeze-smoke")

        let image = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
        let frozen = MacScreenshotFrozenDisplay(
            screenFrame: CGRect(x: 1440, y: -200, width: 8, height: 8),
            image: image
        )
        let selected = try! frozen.crop(CGRect(x: 1442, y: -198,
                                              width: 3, height: 2))
        precondition(selected.frame == CGRect(x: 1442, y: -198,
                                              width: 3, height: 2)
                     && selected.image.width == 6 && selected.image.height == 4,
                     "冻结画面应按外接屏坐标裁切原生像素")
        let window = CGRect(x: 30, y: 15, width: 80, height: 50)
        let shadow = CGContext(data: nil, width: 200, height: 150,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        shadow.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        shadow.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        shadow.setFillColor(NSColor.white.cgColor)
        shadow.fill(CGRect(x: 20, y: 36, width: 160, height: 100))
        let aligned = MacScreenshotGeometry.shadowedWindowFrame(
            image: shadow.makeImage()!, window: window, scale: 2)
        precondition(aligned == CGRect(x: 20, y: -3, width: 100, height: 75),
                     "不对称阴影应按窗口主体定位，保留屏幕边界外的阴影空间")

        let safeArea = CGRect(x: 100, y: 90, width: 900, height: 650)
        let barSize = CGSize(width: 722, height: 56)
        for selection in [CGRect(x: 20, y: 84, width: 100, height: 120),
                          CGRect(x: 0, y: 0, width: 1000, height: 780)] {
            let bar = MacScreenshotGeometry.toolbarFrame(
                near: selection, in: safeArea, size: barSize, gap: 20)
            precondition(safeArea.contains(bar), "工具栏应避开底部及侧边 Dock 区域")
        }
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 220)
        let start = CGPoint(x: 100, y: 100)
        var constraint = MacScreenshotDragConstraint()
        constraint.reset(modifiers: .shift)
        let first = constraint.rect(from: start, to: CGPoint(x: 180, y: 120),
                                    in: bounds, modifiers: .shift)
        let later = constraint.rect(from: start, to: CGPoint(x: 230, y: 180),
                                    in: bounds, modifiers: .shift)
        precondition(first.height == 24 && later.height == 24 && later.width == 130,
                     "Shift 拖选应锁定单轴，不能随方向抖动改变另一个尺寸")
        let released = constraint.rect(from: start, to: CGPoint(x: 230, y: 180),
                                       in: bounds, modifiers: [])
        precondition(released.size == CGSize(width: 130, height: 80), "松开 Shift 应立即恢复自由拖选")
        let centered = constraint.rect(from: start, to: CGPoint(x: 70, y: 115),
                                       in: bounds, modifiers: .option)
        precondition(centered == CGRect(x: 70, y: 100, width: 30, height: 30),
                     "Option 应固定按下点，沿鼠标方向等宽高扩张")
        let edge = constraint.rect(from: CGPoint(x: 5, y: 210), to: CGPoint(x: 50, y: 140),
                                   in: bounds, modifiers: .option)
        precondition(bounds.contains(edge) && edge.width == edge.height && edge.minX == 5 && edge.maxY == 210,
                     "屏幕边缘应限制可用尺寸，保持正方形及起点不变")
        for delta in [CGPoint(x: 40, y: 20), CGPoint(x: -40, y: 20),
                      CGPoint(x: 40, y: -20), CGPoint(x: -40, y: -20)] {
            constraint.reset(modifiers: .option)
            let directed = constraint.rect(from: start,
                to: CGPoint(x: start.x + delta.x, y: start.y + delta.y),
                in: bounds, modifiers: .option)
            precondition(directed.size == CGSize(width: 40, height: 40)
                && (delta.x < 0 ? directed.maxX : directed.minX) == start.x
                && (delta.y < 0 ? directed.maxY : directed.minY) == start.y,
                "Option 四个拖动方向都应固定起点，保持等宽高")
        }
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                             0, 0, 255, 255, 255, 255, 255, 255]
        let swatches = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        let sampleBounds = CGRect(x: 100, y: 200, width: 1, height: 1)
        let red = MacScreenshotPixelSample.at(CGPoint(x: 100.25, y: 200.75),
                                               in: sampleBounds, image: swatches)!
        let blue = MacScreenshotPixelSample.at(CGPoint(x: 100.25, y: 200.25),
                                                in: sampleBounds, image: swatches)!
        precondition(red.hex == "#FF0000" && blue.hex == "#0000FF",
                     "像素放大预览应按原生倍率、左上原点读取准确色值")
        precondition(red.image.width == 2 && red.cropRect == CGRect(x: 0, y: 0, width: 2, height: 2),
                     "屏幕边缘放大预览应裁切有效像素")
        print("Mac screenshot geometry smoke test passed")
    }
}
