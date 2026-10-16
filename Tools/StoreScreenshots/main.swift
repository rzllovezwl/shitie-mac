import AppKit
import SwiftUI

@main
@MainActor
struct StoreScreenshots {
    private static let outputSize = NSSize(width: 2880, height: 1800)

    static func main() throws {
        _ = NSApplication.shared
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = project.appendingPathComponent("distribution/screenshots/zh-Hans", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookStoreScreenshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        var store = ClipboardHistoryStore(directory: fixtures)
        try populate(store)
        var datedEntries = store.entries
        for index in datedEntries.indices {
            datedEntries[index].createdAt = Date().addingTimeInterval(TimeInterval(-180 * (index + 1)))
        }
        let historyURL = fixtures.appendingPathComponent("history.json")
        try JSONEncoder().encode(datedEntries).write(to: historyURL, options: .atomic)
        store = ClipboardHistoryStore(directory: fixtures)
        let model = AppController(store: store)
        model.isPaused = false
        let entries = model.entries
        let imageEntry = entries.first { $0.kind == .image }!
        let textEntry = entries.first { $0.kind == .text }!

        let shelf = shelfPreview(model: model)
        try save(
            view: shelf,
            title: "复制过的，随时找回",
            subtitle: "文字、链接、图片，在屏幕底部一览",
            file: output.appendingPathComponent("01-history.jpg")
        )

        let textDetail = detailOverlay(entry: textEntry, model: model)
        try save(
            view: textDetail,
            title: "选中，按空格查看详情",
            subtitle: "左右方向键切换记录，快速查看完整内容",
            file: output.appendingPathComponent("02-text-detail.jpg")
        )

        let imageDetail = detailOverlay(entry: imageEntry, model: model)
        try save(
            view: imageDetail,
            title: "图片也能清晰预览",
            subtitle: "在详情中用触控板双指捏合缩放",
            file: output.appendingPathComponent("03-image-detail.jpg")
        )

        let settings = SettingsView(model: model)
            .frame(width: 600, height: 900)
            .background(Color(nsColor: .windowBackgroundColor))
        try save(
            view: settings,
            renderSize: CGSize(width: 600, height: 900),
            artworkWidth: 1150,
            title: "按你的习惯整理",
            subtitle: "调整面板、暂停记录，随时清空本机历史",
            file: output.appendingPathComponent("04-settings.jpg")
        )
    }

    private static func populate(_ store: ClipboardHistoryStore) throws {
        _ = try store.addText("周五计划\n09:30 整理会议记录\n14:00 准备新版本素材\n18:00 完成一周回顾", sourceAppName: "备忘录")
        _ = try store.addText("https://example.com/reading-list", sourceAppName: "浏览器")
        _ = try store.addText("一段随手记下的灵感：\n让重要的想法，像刚复制时一样容易找到。", sourceAppName: "备忘录")
        _ = try store.addImage(makeDemoImage(), type: NSPasteboard.PasteboardType.png.rawValue, sourceAppName: "预览")
        _ = try store.addText("项目交付清单\n• 整理说明文档\n• 检查图片与文字\n• 发出最终版本", sourceAppName: "文本编辑")
        _ = try store.addText("设计参考：柔和的光线、清晰的层次、留出呼吸空间。", sourceAppName: "备忘录")
    }

    private static func makeDemoImage() -> Data {
        let size = NSSize(width: 1100, height: 720)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.91, green: 0.78, blue: 0.97, alpha: 1),
            NSColor(calibratedRed: 0.48, green: 0.72, blue: 0.98, alpha: 1)
        ])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

        NSColor(calibratedRed: 1, green: 0.92, blue: 0.76, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: NSRect(x: 760, y: 400, width: 170, height: 170)).fill()

        let back = NSBezierPath()
        back.move(to: NSPoint(x: 0, y: 190))
        back.line(to: NSPoint(x: 310, y: 520))
        back.line(to: NSPoint(x: 600, y: 200))
        back.line(to: NSPoint(x: 850, y: 410))
        back.line(to: NSPoint(x: 1100, y: 130))
        back.line(to: NSPoint(x: 1100, y: 0))
        back.line(to: NSPoint(x: 0, y: 0))
        back.close()
        NSColor(calibratedRed: 0.32, green: 0.50, blue: 0.77, alpha: 0.72).setFill()
        back.fill()

        let front = NSBezierPath()
        front.move(to: NSPoint(x: 0, y: 0))
        front.line(to: NSPoint(x: 0, y: 100))
        front.line(to: NSPoint(x: 260, y: 340))
        front.line(to: NSPoint(x: 520, y: 110))
        front.line(to: NSPoint(x: 810, y: 320))
        front.line(to: NSPoint(x: 1100, y: 70))
        front.line(to: NSPoint(x: 1100, y: 0))
        front.close()
        NSColor(calibratedRed: 0.17, green: 0.32, blue: 0.63, alpha: 0.90).setFill()
        front.fill()
        image.unlockFocus()

        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    private static func detailOverlay(entry: ClipboardEntry, model: AppController) -> some View {
        ZStack {
            shelfPreview(model: model)
            Color.black.opacity(0.18)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .padding(18)
            ClipboardDetailView(
                entry: entry,
                imageURL: model.imageURL(for: entry),
                onCopy: {},
                onClose: {}
            )
            .frame(width: 640, height: 440)
            .background(Color.white.opacity(0.98), in: RoundedRectangle(cornerRadius: 22))
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        }
    }

    private static func shelfPreview(model: AppController) -> some View {
        ShelfView(model: model)
            .preferredColorScheme(.light)
            .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 28))
            .padding(18)
            .background(Color(red: 0.09, green: 0.16, blue: 0.29), in: RoundedRectangle(cornerRadius: 40))
    }

    private static func save<V: View>(
        view: V,
        renderSize: CGSize = CGSize(width: 1376, height: 520),
        artworkWidth: CGFloat = 2752,
        title: String,
        subtitle: String,
        file: URL
    ) throws {
        guard let artwork = renderWindow(view, size: renderSize) else {
            throw NSError(domain: "StoreScreenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法渲染 \(file.lastPathComponent)"])
        }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(outputSize.width),
            pixelsHigh: Int(outputSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "StoreScreenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建画布"])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGradient(colors: [
            NSColor(calibratedRed: 0.87, green: 0.92, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.97, green: 0.98, blue: 1, alpha: 1)
        ])!.draw(in: NSRect(origin: .zero, size: outputSize), angle: -23)

        let glow = NSBezierPath(ovalIn: NSRect(x: 1960, y: 910, width: 980, height: 980))
        NSColor(calibratedRed: 0.41, green: 0.61, blue: 1, alpha: 0.10).setFill()
        glow.fill()

        let isSettings = renderSize.width < 1000
        draw(title, at: NSPoint(x: 110, y: isSettings ? 1390 : 1560), size: 75, weight: .bold,
             color: NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.32, alpha: 1))
        draw(subtitle, at: NSPoint(x: 114, y: isSettings ? 1305 : 1475), size: 31, weight: .regular,
             color: NSColor(calibratedRed: 0.31, green: 0.42, blue: 0.60, alpha: 1))

        let artHeight = CGFloat(artwork.height) * artworkWidth / CGFloat(artwork.width)
        let artworkRect = isSettings
            ? NSRect(x: 1600, y: 50, width: artworkWidth, height: artHeight)
            : NSRect(x: (outputSize.width - artworkWidth) / 2, y: max(95, 1260 - artHeight), width: artworkWidth, height: artHeight)
        NSImage(cgImage: artwork, size: NSSize(width: artwork.width, height: artwork.height))
            .draw(in: artworkRect)

        draw("演示内容", at: NSPoint(x: 110, y: 45), size: 22, weight: .medium,
             color: NSColor(calibratedRed: 0.43, green: 0.51, blue: 0.65, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.96]) else {
            throw NSError(domain: "StoreScreenshots", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法导出 JPEG"])
        }
        try data.write(to: file, options: .atomic)
        print("Created \(file.path)")
    }

    private static func draw(_ value: String, at origin: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        (value as NSString).draw(
            at: origin,
            withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        )
    }

    private static func renderWindow<V: View>(_ view: V, size: CGSize) -> CGImage? {
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.19, blue: 0.32, alpha: 1)
        window.isOpaque = true
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            window.orderOut(nil)
            return nil
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        window.orderOut(nil)
        return bitmap.cgImage
    }
}
