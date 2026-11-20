import AppKit
import SwiftUI

/// Documentation artwork from actual app views and fictional, isolated fixtures.
/// Never starts clipboard polling, registers hotkeys, records a screen or plays sound.
@main
@MainActor
struct RepositoryArtwork {
    static let ink = NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.23, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.37, green: 0.43, blue: 0.53, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.03, green: 0.46, blue: 0.97, alpha: 1)

    static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let demo = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIPHOOOK_ARTWORK_DIR"]!)
        let output = root.appendingPathComponent("docs/images")
        try FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: PhoneScreenshotDiscovery.cardDismissedKey)
        UserDefaults.standard.set(false, forKey: CopySoundPreference.enabledKey)
        UserDefaults.standard.set("compact", forKey: "panelHeight")
        if CommandLine.arguments.contains("--iphone-only") {
            try makePhoneImages(demo: demo, output: output)
            return
        }
        let store = ClipboardHistoryStore(directory: demo.appendingPathComponent("history"))
        let postcard = try makePostcard()
        _ = try store.addText("https://example.com/cliphoook/design-notes", sourceAppName: "Safari")
        _ = try store.addText("func keepAnIdea() {\n    clipboard.save()\n    return later\n}", sourceAppName: "Xcode")
        _ = try store.addText("设计参考\n蓝白配色 · 圆润边缘\n重点清晰，留出空间", sourceAppName: "备忘录")
        _ = try store.addImage(postcard, type: NSPasteboard.PasteboardType.png.rawValue, sourceAppName: "预览")
        _ = try store.addText("# 发布清单\n\n✓ 整理功能说明\n✓ 核对界面与资源\n✓ 完成构建验证\n\n让想法接着发生。", sourceAppName: "备忘录")
        _ = try store.addText("灵感先收好，\n需要时再接着用。", sourceAppName: "文本编辑")
        if let entry = store.entries.first { try store.setFavorites([entry.id], isFavorite: true) }
        let model = AppController.shared
        let shelf = try render(ShelfView(model: model).preferredColorScheme(.light)
            .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 24)),
            size: CGSize(width: 1440, height: 430))
        try save(size: CGSize(width: 1680, height: 980), to: output.appendingPathComponent("overview.jpg")) {
            label("CLIPHOOOK  /  NATIVE MAC WORKSPACE", x: 72, y: 900, size: 17, color: blue, weight: .semibold)
            label("复制过的，都能接着用。", x: 72, y: 792, size: 66, weight: .bold)
            label("剪贴板历史 · 全局搜索 · 暂存箱 · 截图标注 · 录屏", x: 76, y: 735, size: 25, color: muted)
            if let logo = NSImage(contentsOf: root.appendingPathComponent("ClipboardShelf/Assets.xcassets/AppIcon.appiconset/icon_256x256.png")) {
                logo.draw(in: CGRect(x: 1440, y: 750, width: 160, height: 160))
            }
            artwork(shelf, in: CGRect(x: 72, y: 219, width: 1536, height: 459))
            pill("⌘⇧V  唤起面板", x: 80, y: 135, width: 245)
            pill("⌘⇧空格  直接搜索", x: 342, y: 135, width: 295)
            label("原生交互，数据留在本机。", x: 80, y: 73, size: 22, color: muted)
            footer(width: 1680)
        }

        let search = QuickSearchController(model: model)
        search.show(application: nil, target: nil, onDismiss: { _ in })
        let searchImage = try render(QuickSearchView(controller: search, model: model)
            .preferredColorScheme(.light), size: CGSize(width: 780, height: 500))
        search.dismiss(restore: false)

        let stagingStore = StagingShelfStore(directory: demo.appendingPathComponent("staging"))
        let imageURL = demo.appendingPathComponent("设计参考.png")
        try postcard.write(to: imageURL)
        let checklist = demo.appendingPathComponent("发布清单.md")
        try "# 发布清单\n整理说明\n检查界面\n确认交付".write(to: checklist, atomically: true, encoding: .utf8)
        let board = NSPasteboard(name: NSPasteboard.Name("ClipHoook.Readme.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.writeObjects([imageURL as NSURL, checklist as NSURL])
        _ = try stagingStore.receive(board)
        board.clearContents()
        board.setString("https://example.com/design", forType: .string)
        _ = try stagingStore.receive(board)
        let staging = StagingShelfController(store: stagingStore)
        staging.open()
        settle()
        guard let stagingView = NSApp.windows.first(where: { $0.title == "ClipHoook 暂存箱" })?.contentView else {
            throw failure("暂存箱演示视图未创建")
        }
        let stagingImage = try capture(stagingView)
        staging.hide()
        try save(size: CGSize(width: 1680, height: 1000), to: output.appendingPathComponent("search-staging.jpg")) {
            label("找得到，也接得住。", x: 72, y: 875, size: 60, weight: .bold)
            label("搜索全部历史，或把正在拖动的内容先放在手边。", x: 76, y: 820, size: 24, color: muted)
            artwork(searchImage, in: CGRect(x: 72, y: 175, width: 940, height: 603))
            artwork(stagingImage, in: CGRect(x: 1288, y: 235, width: 234, height: 540))
            pill("⌘⇧空格  全局搜索", x: 80, y: 105, width: 310)
            label("拖入暂存 · 空格预览 · 拖出取用", x: 1135, y: 145, size: 21, color: muted)
            footer(width: 1680)
        }

        let editor = MacScreenshotEditorController()
        let base = try makeAnnotationBase()
        guard editor.open(data: base, editableBaseData: base,
            editableDocumentData: try repositoryAnnotationDocument(), maximumBytes: 15 * 1024 * 1024,
            onSave: { _, _ in false }) else { throw failure("标注演示未创建") }
        settle()
        guard let editorView = NSApp.windows.first(where: { $0.title == "标注图片" })?.contentView else {
            throw failure("标注演示视图未创建")
        }
        let editorImage = try capture(editorView)
        NSApp.windows.first(where: { $0.title == "标注图片" })?.orderOut(nil)
        try save(size: CGSize(width: 1680, height: 1360), to: output.appendingPathComponent("annotations.jpg")) {
            label("把重点说清楚。", x: 72, y: 1235, size: 60, weight: .bold)
            label("截图、裁剪与标注，继续完成下一步。", x: 76, y: 1180, size: 24, color: muted)
            let height = 1370 * CGFloat(editorImage.height) / CGFloat(editorImage.width)
            artwork(editorImage, in: CGRect(x: 155, y: 130, width: 1370, height: height))
            label("箭头＋矩形  /  划除  /  复制标注元素  /  每个工具独立默认样式", x: 155, y: 72, size: 22, color: muted)
            footer(width: 1680)
        }
        try makePhoneImages(demo: demo, output: output)
        print("Created repository images from build 349 views and isolated demo data")
    }

    static func makePhoneImages(demo: URL, output: URL) throws {
        let picture = try makePhoneScreenshot()
        let store = ClipboardHistoryStore(directory: demo.appendingPathComponent("phone-history"))
        _ = try store.addImage(picture, type: NSPasteboard.PasteboardType.png.rawValue,
                               sourceAppName: "iPhone 截图", screenshotOrigin: .phone)
        guard let entry = store.entries.first, let imageURL = store.imageURL(for: entry),
              let phoneScreen = NSImage(data: picture) else { throw failure("无法创建 iPhone 演示图片") }
        let card = ClipboardCardView(entry: entry, imageURL: imageURL, thumbnailURL: nil,
            fileHasSavedCopy: false, richTextFiles: .init(rtf: nil, html: nil, rtfd: nil), formattedPreviewEnabled: true,
            cardSize: CGSize(width: 280, height: 360), isSelected: true, groupMembership: nil,
            onSelect: { _ in }, onPaste: {}, onCopy: {}, onDelete: {},
            canRecognizeImage: true, recognizeShortcut: "⌘W", onRecognizeImage: {},
            onOpenSource: {}, onBeginDrag: { nil }, onDragStarted: {}, onEndDrag: { _ in })
        let cardImage = try render(card.preferredColorScheme(.light).padding(2),
                                   size: CGSize(width: 284, height: 364))
        try save(size: CGSize(width: 1680, height: 1180), to: output.appendingPathComponent("iphone-transfer.jpg")) {
            label("iPhone 截图，自动到 Mac。", x: 72, y: 1055, size: 61, weight: .bold)
            label("手机里看到的灵感，接到 Mac 上继续用。", x: 76, y: 998, size: 25, color: muted)
            label("iPhone", x: 235, y: 940, size: 23, weight: .semibold)
            let device = CGRect(x: 145, y: 310, width: 300, height: 600)
            NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: device, xRadius: 48, yRadius: 48).fill()
            NSGraphicsContext.saveGraphicsState()
            let display = device.insetBy(dx: 11, dy: 11)
            NSBezierPath(roundedRect: display, xRadius: 39, yRadius: 39).addClip()
            phoneScreen.draw(in: display)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: CGRect(x: 249, y: 874, width: 92, height: 17), xRadius: 9, yRadius: 9).fill()
            label("保存一张新截图", x: 198, y: 264, size: 23, color: muted)

            blue.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: CGRect(x: 699, y: 651, width: 100, height: 100)).fill()
            if let wifi = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil) {
                let symbol = wifi.withSymbolConfiguration(.init(pointSize: 40, weight: .medium)) ?? wifi
                symbol.draw(in: CGRect(x: 722, y: 682, width: 55, height: 39))
            }
            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: 510, y: 608)); arrow.line(to: CGPoint(x: 992, y: 608))
            arrow.move(to: CGPoint(x: 975, y: 625)); arrow.line(to: CGPoint(x: 992, y: 608))
            arrow.line(to: CGPoint(x: 975, y: 591))
            arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            blue.setStroke(); arrow.stroke()
            label("快捷指令自动发送", x: 624, y: 546, size: 26, weight: .semibold)
            label("同一可信局域网 · 无需 iPhone App", x: 536, y: 500, size: 21, color: muted)

            label("ClipHoook 历史", x: 1137, y: 940, size: 23, weight: .semibold)
            artwork(cardImage, in: CGRect(x: 1100, y: 384, width: 365, height: 468))
            label("预览 · 识别文字 · 标注 · 拖到其他应用", x: 1060, y: 320, size: 21, color: muted)
            pill("①  保存截图", x: 180, y: 143, width: 280)
            pill("②  自动传到 Mac", x: 560, y: 143, width: 330)
            pill("③  接着处理与使用", x: 990, y: 143, width: 350)
            label("先完成一次设置。无需等待照片云同步，截图直接进入剪贴板历史。", x: 180, y: 86, size: 22, color: muted)
            footer(width: 1680)
        }

        let model = AppController.shared
        model.configureRepositoryPhoneFixture()
        let guide = try render(repositoryPhoneGuide(model: model), size: CGSize(width: 660, height: 1040))
        try save(size: CGSize(width: 1680, height: 1400), to: output.appendingPathComponent("iphone-setup.jpg")) {
            label("设置一次，之后截屏就直达。", x: 72, y: 1275, size: 59, weight: .bold)
            label("Mac 开启接收，iPhone 添加快捷指令并启用自动化。", x: 76, y: 1220, size: 25, color: muted)
            artwork(guide, in: CGRect(x: 75, y: 142, width: 650, height: 1024))
            step(1, "Mac 开启接收", "设置 → iPhone 传图\n开启“接收 iPhone 截图”。", x: 815, y: 1005)
            step(2, "iPhone 扫码添加模板", "打开 Mac 的功能指南，\n用 iPhone 扫码添加 iCloud 模板。", x: 815, y: 785)
            step(3, "填入你自己的接收地址", "从 Mac 复制完整地址，\n替换模板 URL 中的占位文字。", x: 815, y: 565)
            step(4, "启用“立即运行”", "保存一张新截图到照片，\n它就会出现在 Mac 的历史中。", x: 815, y: 345)
            label("示意界面使用演示地址；实际设置请复制自己 Mac 中的地址。", x: 78, y: 78, size: 21, color: muted)
            footer(width: 1680)
        }
        print("Created iPhone transfer / setup images; no receiver or network transfer started")
    }

    static func step(_ number: Int, _ title: String, _ description: String, x: CGFloat, y: CGFloat) {
        blue.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: y + 45, width: 52, height: 52)).fill()
        label(String(number), x: x + 17, y: y + 55, size: 28, color: blue, weight: .semibold)
        label(title, x: x + 75, y: y + 56, size: 29, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 10
        (description as NSString).draw(in: CGRect(x: x + 75, y: y - 54, width: 650, height: 98),
            withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: muted, .paragraphStyle: paragraph])
    }

    static func makePhoneScreenshot() throws -> Data {
        let bitmap = try canvas(size: CGSize(width: 760, height: 1580)) {
            NSColor.white.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: 760, height: 1580)).fill()
            label("9:41", x: 65, y: 1460, size: 32, weight: .semibold)
            label("灵感笔记", x: 65, y: 1295, size: 62, weight: .bold)
            label("把喜欢的片刻，留到之后。", x: 68, y: 1218, size: 29, color: muted)
            NSColor(calibratedRed: 0.91, green: 0.95, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 50, y: 630, width: 660, height: 515), xRadius: 36, yRadius: 36).fill()
            label("WEEKEND NOTES", x: 95, y: 1050, size: 22, color: blue, weight: .semibold)
            label("周末的小计划", x: 95, y: 955, size: 48, weight: .bold)
            label("01  整理灵感与参考", x: 95, y: 850, size: 31)
            label("02  做一张喜欢的海报", x: 95, y: 770, size: 31)
            label("03  去看看新的风景", x: 95, y: 690, size: 31)
            label("这张截图，接到 Mac 上继续用。", x: 70, y: 480, size: 29, color: muted)
            label("CLIPHOOOK / DEMO", x: 70, y: 365, size: 22, color: blue)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("无法生成手机截图示例") }
        return data
    }

    static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.55)) }

    static func render<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 60, y: 60), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.contentView = host
        window.orderFrontRegardless()
        settle()
        defer { window.orderOut(nil) }
        return try capture(host)
    }

    static func capture(_ view: NSView) throws -> CGImage {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw failure("无法分配配图画布")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw failure("无法渲染演示视图") }
        return image
    }

    static func save(size: CGSize, to file: URL, draw: () -> Void) throws {
        let bitmap = try canvas(size: size, draw: {
            NSGradient(starting: NSColor(calibratedRed: 0.91, green: 0.95, blue: 1, alpha: 1),
                       ending: NSColor(calibratedRed: 0.98, green: 0.99, blue: 1, alpha: 1))!
                .draw(in: CGRect(origin: .zero, size: size), angle: 25)
            draw()
        })
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.91]) else {
            throw failure("无法导出首页配图")
        }
        try data.write(to: file)
        print("Created \(file.lastPathComponent) (\(data.count) bytes)")
    }

    static func canvas(size: CGSize, draw: () -> Void) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw failure("无法创建画布") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func artwork(_ image: CGImage, in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.13, green: 0.25, blue: 0.42, alpha: 0.15)
        shadow.shadowBlurRadius = 25
        shadow.shadowOffset = CGSize(width: 0, height: -10)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).addClip()
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      color: NSColor? = nil, weight: NSFont.Weight = .regular) {
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? ink
        ])
    }

    static func pill(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) {
        blue.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: 51), xRadius: 25, yRadius: 25).fill()
        label(text, x: x + 22, y: y + 12, size: 21, color: blue, weight: .medium)
    }

    static func footer(width: CGFloat) {
        label("CLIPHOOOK  ·  DEVELOP 349", x: 72, y: 26, size: 14, color: muted)
        label("虚构演示内容 · 当前应用界面", x: width - 350, y: 26, size: 14, color: muted)
    }

    static func makePostcard() throws -> Data {
        let bitmap = try canvas(size: CGSize(width: 760, height: 520)) {
            NSColor(calibratedRed: 0.90, green: 0.94, blue: 1, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: 760, height: 520)).fill()
            blue.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: CGRect(x: 420, y: 150, width: 370, height: 370)).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: CGRect(x: 95, y: 95, width: 570, height: 330), xRadius: 28, yRadius: 28).fill()
            label("KEEP AN IDEA.", x: 140, y: 345, size: 19, color: blue, weight: .semibold)
            label("让灵感", x: 140, y: 250, size: 58, weight: .bold)
            label("接着发生。", x: 140, y: 175, size: 58, weight: .bold)
            label("CLIPHOOOK", x: 140, y: 125, size: 18, color: muted)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("无法生成图片样例") }
        return data
    }

    static func makeAnnotationBase() throws -> Data {
        let bitmap = try canvas(size: CGSize(width: 1200, height: 760)) {
            NSColor.white.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1200, height: 760)).fill()
            label("本周发布清单", x: 90, y: 645, size: 44, weight: .bold)
            label("把关键内容框出来，把旧方案划掉。", x: 93, y: 598, size: 23, color: muted)
            NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 80, y: 270, width: 730, height: 285), xRadius: 22, yRadius: 22).fill()
            label("整理说明 · 检查界面 · 确认交付", x: 132, y: 473, size: 30, weight: .medium)
            label("已废弃的旧方案", x: 144, y: 369, size: 28, color: muted)
            label("保留重点，让信息更容易被看懂。", x: 115, y: 170, size: 27, color: muted)
            label("ClipHoook / 截图与图片标注", x: 115, y: 115, size: 20, color: blue)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("无法生成标注样例") }
        return data
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "ClipHoook.RepositoryArtwork", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
