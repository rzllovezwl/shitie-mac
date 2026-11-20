import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct StagingShelfSmoke {
    enum Failure: Error { case failed(String) }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipHoookStaging-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let generalChangeCount = NSPasteboard.general.changeCount
        try testGateAndGeometry()
        try testAppearanceMotion()
        try await testPreviewSession()
        try testNativeFileBoards(in: root)
        let directory = root.appendingPathComponent("staging")
        let store = StagingShelfStore(directory: directory)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        func put(_ objects: [NSPasteboardWriting]) throws {
            board.clearContents()
            try check(board.writeObjects(objects), "测试拖动数据未写入")
        }
        func text(_ value: String) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            return item
        }
        try put([text("临时文字"), text("https://example.com/?keep=1#part")])
        try check(StagingShelfStore.supports(board), "文字和链接拖动应受支持")
        try check(try store.receive(board) == 2 && store.items.map(\.kind) == [.text, .link], "应分别收集文字和链接")
        let firstIDs = store.items.map(\.id)
        try check(try store.receive(board) == 0 && store.items.map(\.id) == firstIDs, "重复收集不应新增或替换内容")
        let payload = try store.dragPayload(ids: Set(firstIDs))
        let textPreview = try store.previewPayload(id: firstIDs[0])
        guard case .text(let previewText) = textPreview.content else { throw Failure.failed("文字应直接预览") }
        try check(previewText == "临时文字" && textPreview.access == nil, "文字预览不能截断或改写内容")
        let linkPreview = try store.previewPayload(id: firstIDs[1])
        guard case .text(let previewLink) = linkPreview.content else { throw Failure.failed("链接应显示原文，不请求网页") }
        try check(previewLink == "https://example.com/?keep=1#part", "链接预览必须保留参数和片段")
        try check(textPreview.previewEntry.kind == .text && textPreview.previewEntry.text == previewText &&
                  linkPreview.previewEntry.kind == .link && linkPreview.previewEntry.text == previewLink,
                  "复用剪贴板预览时，文字和链接只转换视图模型，保留完整原文")
        try put(payload.writers)
        try check(board.pasteboardItems?.first?.string(forType: .string) == "临时文字" &&
                  board.pasteboardItems?.last?.string(forType: .URL) == "https://example.com/?keep=1#part",
                  "文字和链接应按原类型拖出，保留全部参数")
        try check(store.items.count == 2, "取出不应自动移除暂存")
        try store.editText(id: firstIDs[0], text: "已编辑的暂存文字")
        try check(store.items[0].id == firstIDs[0] && store.items[0].text == "已编辑的暂存文字",
                  "暂存文字编辑应保留身份并更新原文")
        try check(StagingShelfStore(directory: directory).items.first?.text == "已编辑的暂存文字",
                  "暂存文字编辑应持久化")
        do { try store.editText(id: firstIDs[0], text: "https://example.com/?keep=1#part"); throw Failure.failed("重复文字应拒绝") }
        catch StagingShelfError.duplicateText {}

        // Sparse multi-GB file: only the reference and security bookmark may be stored.
        let huge = root.appendingPathComponent("5GB-test.bin")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 5 * 1_024 * 1_024 * 1_024)
        try handle.close()
        try put([huge as NSURL])
        try check(try store.receive(board) == 1 && store.items.last?.ownedBytes == 0, "大文件只能保存位置，不能复制其内容")
        let fileItem = store.items.last!
        let filePreview = try store.previewPayload(id: fileItem.id)
        guard case .file(let previewURL) = filePreview.content else { throw Failure.failed("文件须交给系统预览") }
        try check(previewURL == huge && filePreview.access?.url == huge,
                  "大文件预览只能传递原 URL，并在预览期间保留访问权")
        try check(filePreview.previewEntry.kind == .fileReference && filePreview.previewEntry.filePath == huge.path,
                  "复用文件详情时必须继续使用原文件引用")
        try check(fileItem.kind == .file && fileItem.filePath == huge.path, "文件类型或路径不正确")
        let diskFiles = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        try check(diskFiles.allSatisfy { $0 == "Images" || $0 == "items.json" } &&
                  (try Data(contentsOf: directory.appendingPathComponent("items.json"))).count < 32_000,
                  "收集 5 GB 文件后不应产生文件副本")
        let filePayload = try store.dragPayload(ids: [fileItem.id])
        try check(filePayload.accesses.count == 1 && filePayload.accesses[0].url == huge,
                  "文件拖出时应持续保留原文件访问权")
        try put(filePayload.writers)
        try check((board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL) == huge,
                  "拖出应提供真实文件 URL")

        let png = try fixtureImage(type: .png)
        let imageWriter = NSPasteboardItem()
        imageWriter.setData(png, forType: .png)
        try put([imageWriter, imageWriterCopy(png)])
        try check(try store.receive(board) == 1, "同批相同图片只应收集一次")
        let imageItem = store.items.last!
        guard let imageURL = store.imageURL(for: imageItem) else { throw Failure.failed("图片未本机保存") }
        let imagePreview = try store.previewPayload(id: imageItem.id)
        guard case .file(let previewImageURL) = imagePreview.content else { throw Failure.failed("独立图片应可预览") }
        try check(previewImageURL == imageURL, "图片预览应使用暂存中的原图，不另存副本")
        try check(imagePreview.previewEntry.kind == .image && imagePreview.previewEntry.filePath == imageURL.path,
                  "暂存图片应交给剪贴板的图片缩放预览，并继续读取暂存原图")
        try check(try Data(contentsOf: imageURL) == png, "PNG 暂存内容应完整")
        try check(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Images").path).count == 1,
                  "去重后不应遗留多余图片文件")
        let imagePayload = try store.dragPayload(ids: [imageItem.id])
        try put(imagePayload.writers)
        try check(board.pasteboardItems?.first?.data(forType: .png) == png &&
                  board.pasteboardItems?.first?.string(forType: .fileURL) == imageURL.absoluteString,
                  "图片应同时提供图像和文件 URL，方便不同目标应用接收")
        let deliveryStore = StagingShelfStore(directory: root.appendingPathComponent("delivery"))
        try put([imageWriterCopy(png)])
        _ = try deliveryStore.receive(board)
        let deliveryItem = deliveryStore.items[0]
        let deliveryURL = deliveryStore.imageURL(for: deliveryItem)!
        try deliveryStore.remove([deliveryItem.id], afterSuccessfulExport: true)
        try check(deliveryStore.items.isEmpty && (try Data(contentsOf: deliveryURL)) == png,
                  "成功取出立即移除列表，但给异步读取的目标暂留图片文件")
        deliveryStore.cleanupExportedImages(now: .now.addingTimeInterval(65))
        try check(!FileManager.default.fileExists(atPath: deliveryURL.path), "投放宽限到期后应回收内部图片文件")
        let reopened = StagingShelfStore(directory: directory)
        try check(reopened.items == store.items, "重启后应恢复全部暂存记录")
        try check(reopened.fileAccess(for: fileItem)?.url.resolvingSymlinksInPath() == huge.resolvingSymlinksInPath(),
                  "重启后的书签应恢复到同一个原文件（允许系统规范化路径）")
        let untouched = root.appendingPathComponent("preserve-original.txt")
        let untouchedData = Data("不可删除的原文件".utf8)
        try untouchedData.write(to: untouched)
        try put([untouched as NSURL])
        _ = try store.receive(board)

        // History image URLs must survive later cleanup of their history entry.
        let historyImage = root.appendingPathComponent("history-image.png")
        let differentPNG = try fixtureImage(type: .png, width: 17)
        try differentPNG.write(to: historyImage)
        store.isHistoryImage = { $0 == historyImage }
        try put([historyImage as NSURL])
        try check(try store.receive(board) == 1 && store.items.last?.kind == .image,
                  "从剪贴板拖入的图片应独立保存")
        try FileManager.default.removeItem(at: historyImage)
        _ = try store.dragPayload(ids: [store.items.last!.id])

        let tiff = NSPasteboardItem()
        tiff.setData(try fixtureImage(type: .tiff, width: 21), forType: .tiff)
        try put([tiff])
        try check(try store.receive(board) == 1, "TIFF 图片应可规范保存")
        let convertedURL = store.imageURL(for: store.items.last!)!
        let converted = CGImageSourceCreateWithURL(convertedURL as CFURL, nil)!
        try check(CGImageSourceGetType(converted) as String? == UTType.png.identifier, "独立 TIFF 图片应转为可拖出的 PNG")

        let oldItems = store.items
        let originalManifest = try Data(contentsOf: directory.appendingPathComponent("items.json"))
        let oldAssets = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Images").path)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("items.json"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("items.json"), withIntermediateDirectories: true)
        try put([imageWriterCopy(try fixtureImage(type: .png, width: 19))])
        do { _ = try store.receive(board); throw Failure.failed("清单保存失败应回滚") }
        catch is Failure { throw Failure.failed("清单保存失败应回滚") }
        catch {}
        try check(store.items == oldItems && Set(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Images").path)) == Set(oldAssets),
                  "保存失败不应改变已有暂存或遗留图片")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("items.json"))
        try originalManifest.write(to: directory.appendingPathComponent("items.json"), options: .atomic)
        try put([text(String(repeating: "x", count: StagingShelfStore.maximumTextBytes + 1))])
        do { _ = try store.receive(board); throw Failure.failed("超大文字应被拒绝") }
        catch StagingShelfError.tooLarge {}
        try check(store.items == oldItems, "超限不应更改已有内容")
        try put([text("不能部分提交"), imageWriterCopy(Data("invalid image".utf8))])
        do { _ = try store.receive(board); throw Failure.failed("整批应拒绝无效图片") }
        catch StagingShelfError.tooLarge {}
        try check(store.items == oldItems, "批次失败不应部分提交")

        try FileManager.default.removeItem(at: huge)
        do { _ = try store.dragPayload(ids: [fileItem.id]); throw Failure.failed("失效文件不应开始拖动") }
        catch StagingShelfError.missingFile {}
        do { _ = try store.previewPayload(id: fileItem.id); throw Failure.failed("失效文件不能交给预览渲染器") }
        catch StagingShelfError.missingFile {}
        try check(store.items == oldItems, "文件失效仍应保留记录供用户处理")
        try store.remove([imageItem.id])
        try check(!FileManager.default.fileExists(atPath: imageURL.path), "移除图片应释放自有图片空间")
        do { _ = try store.previewPayload(id: imageItem.id); throw Failure.failed("移除后不能预览旧图片") }
        catch StagingShelfError.unsupported {}
        try store.remove(Set(store.items.map(\.id)))
        try check(StagingShelfStore(directory: directory).items.isEmpty, "清空应持久化")
        try check(try Data(contentsOf: untouched) == untouchedData, "清空暂存不得删除或修改原文件")

        let capacity = StagingShelfStore(directory: root.appendingPathComponent("capacity"), ownedByteLimit: 20)
        try put([text("1234567890")])
        _ = try capacity.receive(board)
        try put([text("abcdefghijklmnop")])
        do { _ = try capacity.receive(board); throw Failure.failed("总容量超限应拒绝") }
        catch StagingShelfError.tooLarge {}
        try check(capacity.items.count == 1 && capacity.items.first?.text == "1234567890", "容量超限不能淘汰已有内容")

        let limit = StagingShelfStore(directory: root.appendingPathComponent("limit"))
        try put((0..<StagingShelfStore.maximumItems).map { text("第 \($0) 项") })
        try check(try limit.receive(board) == 100, "应可收集 100 项")
        try put([text("第 101 项")])
        do { _ = try limit.receive(board); throw Failure.failed("超出条数应拒绝") }
        catch StagingShelfError.tooManyItems {}
        try check(limit.items.count == 100, "条数超限不能覆盖或丢弃已有内容")
        let corruptFolder = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        let corruptURL = corruptFolder.appendingPathComponent("items.json")
        let invalid = Data("broken manifest".utf8)
        try invalid.write(to: corruptURL)
        let corrupt = StagingShelfStore(directory: corruptFolder)
        do { _ = try corrupt.receive(board); throw Failure.failed("损坏清单应阻止覆盖") }
        catch StagingShelfError.unavailable {}
        try check(try Data(contentsOf: corruptURL) == invalid, "不应覆盖无法读取的暂存数据")
        try check(NSPasteboard.general.changeCount == generalChangeCount, "暂存和拖出不得改写系统剪贴板")
        print("Staging shelf smoke passed: reversible edge animation, reduced motion, Dock drag metadata fallback, drag gating, screen geometry, native/legacy file boards without copies, images, multi-export, restart, dedup, limits and atomic rollback")
    }

    @MainActor
    static func imageWriterCopy(_ data: Data) -> NSPasteboardItem {
        let item = NSPasteboardItem(); item.setData(data, forType: .png); return item
    }

    static func fixtureImage(type: UTType, width: Int = 12) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw Failure.failed("测试图片未生成") }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, type.identifier as CFString, 1, nil) else {
            throw Failure.failed("测试图片未编码")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.failed("测试图片编码失败") }
        return result as Data
    }

    static func testGateAndGeometry() throws {
        let screens = [CGRect(x: 0, y: 50, width: 1440, height: 820),
                       CGRect(x: -1920, y: -900, width: 1920, height: 1080)]
        for screen in screens {
            for x in [screen.minX + 30, screen.maxX - 180] {
                let original = CGRect(x: x, y: screen.midY - 180, width: 156, height: 360)
                let edge = StagingShelfPlacement.edge(for: original, in: screen)
                let tab = StagingShelfPlacement.collapsedFrame(for: original, in: screen)
                try check(screen.contains(tab) && tab.width == 18 && tab.height == 84,
                          "主屏和负坐标外接屏上的侧边标签均须在可用区域内")
                try check(edge == .left ? tab.minX == screen.minX : tab.maxX == screen.maxX,
                          "收起标签必须贴着暂存箱所在的屏幕侧边")
                for inverted in [false, true] {
                    var gesture = StagingShelfEdgeSwipe()
                    let outward: CGFloat = (edge == .left ? 1 : -1) * (inverted ? -1 : 1)
                    try check(!gesture.update(x: outward * 20, y: 1, inverted: inverted, edge: edge) &&
                               gesture.update(x: outward * 22, y: 1, inverted: inverted, edge: edge),
                              "两指横向滑动应达到阈值才收起，兼容自然滚动设置")
                    try check(!gesture.update(x: outward * 80, y: 0, inverted: inverted, edge: edge), "同次手势只能收起一次")
                    gesture.reset()
                    try check(!gesture.update(x: -outward * 80, y: 0, inverted: inverted, edge: edge), "向屏幕内部滑动不能收起")
                    gesture.reset()
                    try check(!gesture.update(x: outward * 42, y: 80, inverted: inverted, edge: edge), "竖向浏览文件不能误收起")
                }
            }
        }
        var gate = StagingDragGate(changeCount: 10)
        gate.mouseDown(changeCount: 10)
        try check(!gate.update(buttonDown: true, changeCount: 10, supported: true, blocked: false),
                  "旧拖动内容不能使窗口移动、截图或普通鼠标拖动误弹暂存箱")
        try check(!gate.update(buttonDown: true, changeCount: 11, supported: false, blocked: false), "不支持的拖动不应出现")
        try check(gate.update(buttonDown: true, changeCount: 11, supported: true, blocked: false), "有效新拖动应出现")
        gate.suppressUntilRelease()
        try check(!gate.update(buttonDown: true, changeCount: 12, supported: true, blocked: false), "Esc 后不应反复弹出")
        _ = gate.update(buttonDown: false, changeCount: 12, supported: true, blocked: false)
        gate.mouseDown(changeCount: 12)
        try check(!gate.update(buttonDown: true, changeCount: 13, supported: true, blocked: true), "截图和导出期间应停止出现")
        try check(!gate.update(buttonDown: true, changeCount: 12, supported: false, blocked: true, nativeDragDetected: true),
                  "截图期间即使有原生拖动图像，也不能弹出暂存箱")
        try check(gate.update(buttonDown: true, changeCount: 12, supported: false, blocked: false, nativeDragDetected: true),
                  "Dock 未更新公开拖放剪贴板时，应由真实拖动图像触发")
        gate.suppressUntilRelease()
        try check(!gate.update(buttonDown: true, changeCount: 12, supported: false, blocked: false, nativeDragDetected: true),
                  "按 Esc 或主动隐藏后，Dock 拖动图像不能反复唤起暂存箱")
        _ = gate.update(buttonDown: false, changeCount: 12, supported: false, blocked: false)
        // No mouseDown callback: keep the last idle baseline and accept a new drag.
        try check(gate.update(buttonDown: true, changeCount: 13, supported: true, blocked: false),
                  "Dock 吞掉鼠标按下事件时仍应能识别新拖动")

        let pointer = StagingNativeDragDetection.quartzPointer(CGPoint(x: 900, y: 60), primaryScreenTop: 900)
        try check(pointer == CGPoint(x: 900, y: 840), "主屏左下坐标须转为窗口列表的左上坐标")
        try check(StagingNativeDragDetection.quartzPointer(CGPoint(x: -500, y: -400), primaryScreenTop: 900)
                  == CGPoint(x: -500, y: 1300), "外接屏负坐标的拖动图像也应正确匹配")
        let drag: [String: Any] = [kCGWindowLayer as String: CGWindowLevelForKey(.draggingWindow),
                                  kCGWindowAlpha as String: 1.0,
                                  kCGWindowBounds as String: CGRect(x: 875, y: 815, width: 48, height: 48).dictionaryRepresentation]
        try check(StagingNativeDragDetection.hasDragImage(in: [drag], pointer: pointer), "鼠标附近原生拖动图像应被识别")
        var ordinary = drag
        ordinary[kCGWindowLayer as String] = 0
        try check(!StagingNativeDragDetection.hasDragImage(in: [ordinary], pointer: pointer), "移动普通窗口不能误认为文件拖动")
        ordinary[kCGWindowLayer as String] = CGWindowLevelForKey(.popUpMenuWindow)
        try check(!StagingNativeDragDetection.hasDragImage(in: [ordinary], pointer: pointer), "Dock 菜单本身不能触发")
        var invisible = drag
        invisible[kCGWindowAlpha as String] = 0
        try check(!StagingNativeDragDetection.hasDragImage(in: [invisible], pointer: pointer), "已隐藏的拖动残留窗口不能触发")
        try check(!StagingNativeDragDetection.hasDragImage(in: [drag], pointer: CGPoint(x: -1000, y: 500)),
                  "其他屏幕远离鼠标的拖动残影不能触发")
        for screen in [CGRect(x: 0, y: 70, width: 1440, height: 800),
                       CGRect(x: -1920, y: -700, width: 1920, height: 1000)] {
            for x in [screen.minX + 10, screen.maxX - 10] {
                for y in [screen.minY, screen.midY, screen.maxY] {
                    let frame = StagingShelfPlacement.frame(pointer: CGPoint(x: x, y: y), visibleFrame: screen,
                                                           size: StagingShelfPlacement.defaultSize)
                    try check(screen.contains(frame), "主屏和外接屏应避开菜单栏及 Dock，不超出屏幕")
                    try check(x < screen.midX ? frame.midX < screen.midX : frame.midX > screen.midX,
                              "暂存箱应位于靠近鼠标的一侧")
                }
            }
        }
        let smallScreen = CGRect(x: 0, y: 30, width: 1024, height: 400)
        try check(smallScreen.contains(StagingShelfPlacement.frame(pointer: CGPoint(x: 1000, y: 50),
            visibleFrame: smallScreen, size: StagingShelfPlacement.defaultSize)), "长列表在较小屏幕上也必须完整位于可用区域")
        try check(StagingShelfPlacement.defaultSize.width == 156 && StagingShelfPlacement.defaultSize.height == 360,
                  "暂存面板应使用更紧凑的默认尺寸")
        for count in [0, 1, 2, 3, 30, 100] {
            let frames = StagingShelfGridLayout.frames(count: count, width: 140)
            let height = StagingShelfGridLayout.contentHeight(count: count, viewportHeight: 266)
            try check(frames.count == count && frames.allSatisfy { CGRect(x: 0, y: 0, width: 140, height: height).contains($0) },
                      "全部暂存项必须位于滚动范围内，包括奇数数量")
            for (index, frame) in frames.enumerated() {
                try check(frame.minX == 0 && frame.width == 140 &&
                          frames.dropFirst(index + 1).allSatisfy { !frame.intersects($0) }, "单列缩略图不能相互重叠")
            }
        }
    }

    @MainActor
    static func testPreviewSession() async throws {
        let payload = StagingShelfPreviewPayload(id: UUID(), name: "OCR.png",
            content: .file(URL(fileURLWithPath: "/private/tmp/staging-preview-ocr.png")), access: nil)
        let session = StagingShelfPreviewSession(payload) { _ in "我的 staging 文字" }
        let task = session.recognize()
        try check(session.canUseImage && session.isRecognizing && session.recognize() == nil,
                  "识别加载应立即可见，重复点击不能启动重复请求")
        await task?.value
        try check(session.entry.ocrText == "我的 staging 文字" && !session.isRecognizing && session.ocrError == nil,
                  "首次识别完成应更新共享预览，并停止加载")
        session.request(.translateScreenshot)
        try check(session.actionRequest?.entryID == payload.id && session.actionRequest?.action == .translateScreenshot,
                  "翻译快捷键必须只路由当前暂存预览")
        let cancelled = StagingShelfPreviewSession(payload) { _ in
            try? await Task.sleep(for: .milliseconds(10)); return "已取消的结果"
        }
        let late = cancelled.recognize()
        cancelled.cancelRecognition()
        await late?.value
        try check(cancelled.entry.ocrText == nil && !cancelled.isRecognizing,
                  "关闭预览后，已取消识别的迟到结果不能重新写回界面")
        let failed = StagingShelfPreviewSession(payload) { _ in throw StagingShelfError.unavailable }
        await failed.recognize()?.value
        try check(failed.ocrError != nil && !failed.isRecognizing, "识别失败必须结束加载并给出可见错误")
    }

    static func testAppearanceMotion() throws {
        for screen in [CGRect(x: 0, y: 30, width: 1440, height: 870),
                       CGRect(x: -1920, y: -800, width: 1920, height: 1080)] {
            for x in [screen.minX + 10, screen.maxX - 10] {
                let full = StagingShelfPlacement.frame(pointer: CGPoint(x: x, y: screen.midY),
                    visibleFrame: screen, size: StagingShelfPlacement.defaultSize)
                let tab = StagingShelfPlacement.collapsedFrame(for: full, in: screen)
                let initial = StagingShelfAppearancePose(frame: full, opacity: 1, collapsed: false)
                for reduced in [false, true] {
                    let closing = StagingShelfAppearanceMotion(from: initial, expandedFrame: full, tabFrame: tab,
                        targetCollapsed: true, reducedMotion: reduced)
                    try check(closing.pose(at: -1) == initial && closing.pose(at: 0) == initial,
                              "收起不能在第一帧跳位置、变大小或提前隐藏内容")
                    try check(closing.pose(at: 1) == closing.finalPose && closing.finalPose.frame == tab,
                              "动画必须在有限时间内落在完整可点击的侧边标签上")
                    let opening = StagingShelfAppearanceMotion(from: closing.finalPose, expandedFrame: full, tabFrame: tab,
                        targetCollapsed: false, reducedMotion: reduced)
                    try check(opening.pose(at: 0) == closing.finalPose && opening.pose(at: 1) == initial,
                              "展开应从标签原位置开始，准确恢复完整面板与不透明度")
                    for motion in [closing, opening] {
                        for step in 0...280 {
                            let pose = motion.pose(at: motion.duration * Double(step) / 280)
                            try check(pose.frame.size == (pose.collapsed ? tab.size : full.size),
                                      "动画只能移动和淡化，不能压缩文件列表或挤小文字")
                            try check(screen.contains(pose.frame) && (0...1).contains(pose.opacity),
                                      "主屏和负坐标外接屏上不能越界或产生透明度过冲")
                            if reduced {
                                try check(pose.frame == (pose.collapsed ? tab : full),
                                          "系统减少动态效果开启时只做短淡入淡出，不侧移内容")
                            }
                        }
                        // Interrupt both before and after the invisible layout
                        // handoff, in both directions, including rapid repeats.
                        for fraction in [0.0, 0.15, 0.5, 0.8, 0.99] {
                            let current = motion.pose(at: motion.duration * fraction)
                            let reversed = StagingShelfAppearanceMotion(from: current, expandedFrame: full, tabFrame: tab,
                                targetCollapsed: !motion.targetCollapsed, reducedMotion: reduced)
                            try check(reversed.pose(at: 0) == current,
                                      "连续点击或反向手势必须接续当前画面，不能重置到起点")
                            try check(reversed.pose(at: reversed.duration) == reversed.finalPose,
                                      "中途反向后也必须完成，不能停在半透明状态")
                        }
                    }
                    let before = closing.pose(at: closing.duration * (0.72 - 0.0001))
                    let after = closing.pose(at: closing.duration * 0.72)
                    try check(before.opacity < 0.000001 && after.opacity == 0 && after.collapsed,
                              "完整面板与标签的布局切换必须发生在完全不可见时")
                    try check(reduced ? closing.duration < 0.2 : closing.duration < 0.35,
                              "收起和展开不应拖延，减少动态效果时应进一步缩短")
                }
            }
        }
    }

    @MainActor
    static func testNativeFileBoards(in root: URL) throws {
        let directory = root.appendingPathComponent("native-file-formats")
        let store = StagingShelfStore(directory: directory)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let file = root.appendingPathComponent("Dock file 测试.png")
        try Data("测试文件格式，不读取内容".utf8).write(to: file)
        let writer = NSPasteboardItem()
        writer.setString(file.absoluteString, forType: .fileURL)
        board.clearContents()
        try check(board.writeObjects([writer]) && StagingShelfStore.supports(board), "原生文件 URL 格式应可接收")
        try check(try store.receive(board) == 1 && store.items.first?.filePath == file.path,
                  "从真正投放的拖放剪贴板读取文件位置，不依赖公开 NSDragPboard")
        let sameID = store.items.first!.id
        board.clearContents()
        board.setPropertyList([file.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        try check(StagingShelfStore.supports(board) && (try store.receive(board)) == 0 && store.items.first?.id == sameID,
                  "兼容旧文件名列表格式，且同一文件不能重复暂存")
        let payload = try store.dragPayload(ids: [sameID])
        try check(payload.writers.count == 1 && payload.accesses.first?.url == file && store.items.first?.ownedBytes == 0,
                  "Dock 类文件投放后可拖出，仍只保留位置和访问权")
    }

    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.failed(message) } }
}
