import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum WeChatImageTestError: Error { case failed(String) }

@main
struct WeChatImageSmoke {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookWeChatImage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ClipHoookWeChatImage-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw WeChatImageTestError.failed("无法创建隔离设置")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HistoryRetention.forever.rawValue, forKey: HistoryStoragePolicy.retentionKey)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw WeChatImageTestError.failed("无法生成测试图") }
        let pixelColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        for y in 0..<8 {
            for x in 0..<8 { bitmap.setColor(pixelColor, atX: x, y: y) }
        }
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw WeChatImageTestError.failed("无法生成 JPEG")
        }
        let temporaryImage = root.appendingPathComponent("wechat-cache.jpg")
        try jpeg.write(to: temporaryImage)
        let item = NSPasteboardItem()
        _ = item.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))

        try check(ClipboardImageCapture.capture(
            items: [item], fileURLs: [temporaryImage],
            sourceAppName: "访达", sourceAppBundleID: "com.apple.finder",
            maximumBytes: 1_000_000
        ) == nil, "访达复制的图片文件应保留文件引用")
        try check(!ClipboardImageCapture.isWeChatImageReference(
            fileURLs: [temporaryImage], sourceAppName: "访达",
            sourceAppBundleID: "com.apple.finder"
        ), "访达图片不应被标记为微信临时图片")

        guard let captured = ClipboardImageCapture.capture(
            items: [item], fileURLs: [temporaryImage],
            sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumBytes: 1_000_000
        ) else { throw WeChatImageTestError.failed("没有优先读取微信提供的 JPEG 内容") }
        try check(captured.data == jpeg && captured.type == UTType.jpeg.identifier, "JPEG 数据或类型变化")
        guard let fileOnlyCapture = ClipboardImageCapture.capture(
            items: [], fileURLs: [temporaryImage],
            sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumBytes: 1_000_000
        ) else { throw WeChatImageTestError.failed("微信仅提供临时文件地址时无法读取图片") }
        try check(fileOnlyCapture.data == jpeg && fileOnlyCapture.type == UTType.jpeg.identifier,
                  "微信临时文件未按 JPEG 保存")

        let store = ClipboardHistoryStore(directory: root.appendingPathComponent("History"), defaults: defaults)
        try check(try store.addImage(captured.data, type: captured.type, sourceAppName: "微信"),
                  "微信图片无法存入历史")
        let entry = store.entries[0]
        let saved = store.imageURL(for: entry)
        try check(entry.kind == .image && saved?.pathExtension == "jpg",
                  "微信图片仍被存成文件引用或扩展名错误")
        guard let saved else { throw WeChatImageTestError.failed("保存的 JPEG 文件不存在") }
        try check(try Data(contentsOf: saved) == jpeg, "保存的图像内容不一致")

        let mixedBoard = NSPasteboard.withUniqueName()
        defer { mixedBoard.releaseGlobally() }
        let imageMessage = NSPasteboardItem()
        _ = imageMessage.setString(temporaryImage.absoluteString, forType: .fileURL)
        _ = imageMessage.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        let textMessage = NSPasteboardItem()
        _ = textMessage.setString("我这个好玩", forType: .string)
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([imageMessage, textMessage]), "无法构造微信图文剪贴板")
        let mixed = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(mixed.count == 2, "微信图片和文字没有同时被记录")
        if case .image(let imageData, _) = mixed[0],
           case .text("我这个好玩") = mixed[1] {
            try check(imageData == jpeg, "图文复制改变了图片数据")
        } else {
            throw WeChatImageTestError.failed("微信图文复制的顺序或类型错误")
        }
        let mixedStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("MixedHistory"), defaults: defaults
        )
        try check(try mixedStore.addCapturedBatch(
            mixed, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            automaticallyGroup: true
        ), "微信图文批次未能保存")
        try check(mixedStore.rootEntries.map(\.kind) == [.image, .text] &&
                  mixedStore.entries.contains(where: { $0.kind == .group }),
                  "旧微信图文分组没有拆成独立卡片")

        let combinedMessage = NSPasteboardItem()
        _ = combinedMessage.setString(temporaryImage.absoluteString, forType: .fileURL)
        _ = combinedMessage.setString("我这个好玩", forType: .string)
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([combinedMessage]), "无法构造单项微信图文剪贴板")
        let combined = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(combined.count == 2, "同一剪贴板项目的图片和文字没有拆成两个组内项目")
        if case .image(let imageData, _) = combined[0],
           case .text("我这个好玩") = combined[1] {
            try check(imageData == jpeg, "仅有临时文件地址的图文复制丢失图片")
        } else {
            throw WeChatImageTestError.failed("单项微信图文复制的顺序或类型错误")
        }

        let inlineMessage = NSPasteboardItem()
        _ = inlineMessage.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        _ = inlineMessage.setString("我这个好玩", forType: .string)
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([inlineMessage]), "无法构造无文件地址的微信图文剪贴板")
        let inline = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(inline.count == 2, "内嵌图文的一种剪贴板表示被漏掉")

        // A WeChat multi-selection can include an app-private sidecar item
        // between real messages and advertise another image under a private
        // type. Neither should cause the whole pasteboard change to vanish.
        let sidecar = NSPasteboardItem()
        _ = sidecar.setString("selection-state", forType: NSPasteboard.PasteboardType(
            "com.tencent.xinWeChat.selection-state"
        ))
        let privateImage = NSPasteboardItem()
        _ = privateImage.setData(jpeg, forType: NSPasteboard.PasteboardType(
            "com.tencent.xinWeChat.image-data"
        ))
        let multiImageMessage = NSPasteboardItem()
        _ = multiImageMessage.setString(temporaryImage.absoluteString, forType: .fileURL)
        _ = multiImageMessage.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        let multiTextMessage = NSPasteboardItem()
        _ = multiTextMessage.setString("我这个好玩", forType: .string)
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([multiImageMessage, sidecar, privateImage, multiTextMessage]),
                  "无法构造含附加格式的微信图文剪贴板")
        let multiSelection = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(multiSelection.count == 3, "微信多选图片和文字的批次未完整记录")
        if case .image = multiSelection[0], case .image = multiSelection[1],
           case .text("我这个好玩") = multiSelection[2] {
        } else {
            throw WeChatImageTestError.failed("微信多选项目的类型或顺序错误")
        }
        let secondImageMessage = NSPasteboardItem()
        _ = secondImageMessage.setString(temporaryImage.absoluteString, forType: .fileURL)
        _ = secondImageMessage.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        let secondSidecar = NSPasteboardItem()
        _ = secondSidecar.setString("selection-state", forType: NSPasteboard.PasteboardType(
            "com.tencent.xinWeChat.selection-state"
        ))
        let secondPrivateImage = NSPasteboardItem()
        _ = secondPrivateImage.setData(jpeg, forType: NSPasteboard.PasteboardType(
            "com.tencent.xinWeChat.image-data"
        ))
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([secondImageMessage, secondSidecar, secondPrivateImage]),
                  "无法构造仅有多张图片的微信剪贴板")
        let multipleImages = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(multipleImages.count == 2, "微信多张图片只记录了第一张")
        let multiStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("MultiHistory"), defaults: defaults
        )
        try check(try multiStore.addCapturedBatch(
            multiSelection, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            automaticallyGroup: false, preserveOccurrences: true
        ), "微信多选图片和文字未保存")
        try check(multiStore.rootEntries.map(\.kind) == [.image, .image, .text] &&
                  Set(multiStore.rootEntries.map(\.id)).count == 3,
                  "相同图片的微信多选没有按原顺序显示为三张独立卡片")
        let copiedIDs = multiStore.rootEntries.map(\.id)
        _ = try multiStore.addCapturedBatch(
            multiSelection, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            automaticallyGroup: false, preserveOccurrences: true
        )
        try check(multiStore.rootEntries.map(\.id) == copiedIDs &&
                  multiStore.rootEntries.allSatisfy { $0.copyCount == 2 },
                  "重复复制同一批微信消息未更新三张卡片的复制次数")

        // Current WeChat exports an entire selection as one item with an
        // ordered JSON array under this private Qt pasteboard type. Its public
        // file URL represents only the first image.
        let secondFile = root.appendingPathComponent("wechat-cache-2.jpg")
        try jpeg.write(to: secondFile)
        let selection = [
            ["file": temporaryImage.path, "text": "图片占位说明"],
            ["file": secondFile.path, "text": "第二张图片说明"],
            ["text": "我这个好玩"]
        ]
        let selectionData = try JSONSerialization.data(withJSONObject: selection)
        let actualFormatItem = NSPasteboardItem()
        _ = actualFormatItem.setData(selectionData, forType: NSPasteboard.PasteboardType(
            "com.trolltech.anymime.x-xwechat-multiselect-copy"
        ))
        _ = actualFormatItem.setString(temporaryImage.absoluteString, forType: .fileURL)
        _ = actualFormatItem.setString("图片占位说明\n第二张图片说明\n我这个好玩", forType: .string)
        let secondPublicImage = NSPasteboardItem()
        _ = secondPublicImage.setString(secondFile.absoluteString, forType: .fileURL)
        _ = secondPublicImage.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([actualFormatItem, secondPublicImage]),
                  "无法构造带两项公开文件地址的微信多选格式")
        try check(ClipboardBatchCapture.isWeChatMultiSelection(mixedBoard),
                  "未识别微信多选专有格式")
        let actualFormat = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "其他应用", sourceAppBundleID: "other.app",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(actualFormat.count == 3, "微信单项多选只读取了第一个文件地址")
        if case .image = actualFormat[0], case .image = actualFormat[1],
           case .text("我这个好玩") = actualFormat[2] {
        } else {
            throw WeChatImageTestError.failed("微信单项多选的消息顺序或内容错误")
        }
        let actualStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("ActualFormatHistory"), defaults: defaults
        )
        try check(try actualStore.addCapturedBatch(
            actualFormat, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            automaticallyGroup: false, preserveOccurrences: true
        ), "微信实际多选格式未能保存")
        try check(actualStore.rootEntries.map(\.kind) == [.image, .image, .text] &&
                  !actualStore.entries.contains(where: { $0.kind == .group }),
                  "新复制的微信多选没有按原顺序保存为独立卡片")

        // The private selection can appear before WeChat finishes writing its
        // temporary image. A later read of the same pasteboard change must work.
        let delayedFile = root.appendingPathComponent("wechat-delayed.jpg")
        let delayedItem = NSPasteboardItem()
        let delayedData = try JSONSerialization.data(withJSONObject: [
            ["file": delayedFile.path, "text": "图片占位说明"]
        ])
        _ = delayedItem.setData(delayedData, forType: NSPasteboard.PasteboardType(
            "com.trolltech.anymime.x-xwechat-multiselect-copy"
        ))
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([delayedItem]), "无法构造延迟写入的微信图片")
        do {
            _ = try ClipboardBatchCapture.capture(
                from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
                maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
                maximumRichTextBytes: 1_000_000
            )
            throw WeChatImageTestError.failed("尚不存在的微信临时图片被误判为已保存")
        } catch ClipboardBatchCaptureError.unavailableChatImage {
            // The poller will retry this unchanged pasteboard change count.
        }
        let expiredCapture = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000,
            allowUnavailableImagePlaceholder: true
        )
        guard expiredCapture.count == 1,
              case .unavailableImage(let expiredURL) = expiredCapture[0],
              expiredURL.path == delayedFile.path else {
            throw WeChatImageTestError.failed("重试超时后未保留无法读取的图片位置")
        }
        try jpeg.write(to: delayedFile)
        let delayedCapture = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(delayedCapture.count == 1, "延迟写入后仍无法保存同一次微信复制")
        if case .image(let delayedBytes, _) = delayedCapture[0] {
            try check(delayedBytes == jpeg, "延迟写入的图片内容变化")
        } else {
            throw WeChatImageTestError.failed("延迟写入的微信图片类型错误")
        }

        // A real WeChat copy may point into its protected app container with
        // no inline image data. Preserve message order and text even when
        // macOS denies all image reads.
        let protectedDirectory = root.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat/Data", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: protectedDirectory, withIntermediateDirectories: true
        )
        let protectedFile = protectedDirectory.appendingPathComponent("wechat-protected.jpg")
        let secondProtectedFile = protectedDirectory.appendingPathComponent("wechat-protected-2.jpg")
        try jpeg.write(to: protectedFile)
        try jpeg.write(to: secondProtectedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: protectedFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: secondProtectedFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                    ofItemAtPath: protectedFile.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                    ofItemAtPath: secondProtectedFile.path)
        }
        let threeMessages = NSPasteboardItem()
        let threeMessageSelection = try JSONSerialization.data(withJSONObject: [
            ["text": "第一条文字"],
            ["file": protectedFile.path, "text": "图片占位说明"],
            ["text": "第三条文字"]
        ])
        _ = threeMessages.setData(threeMessageSelection, forType: NSPasteboard.PasteboardType(
            "com.trolltech.anymime.x-xwechat-multiselect-copy"
        ))
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([threeMessages]), "无法构造三条微信消息")
        let threeCaptured = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        let threeStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("ThreeMessages"), defaults: defaults
        )
        try check(try threeStore.addCapturedBatch(
            threeCaptured, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            automaticallyGroup: false, preserveOccurrences: true
        ), "三条微信消息未能保存")
        try check(threeStore.rootEntries.map(\.kind) == [.text, .unavailableImage, .text] &&
                  threeStore.rootEntries[0].text == "第一条文字" &&
                  threeStore.rootEntries[2].text == "第三条文字",
                  "文字、缺图、文字没有按微信消息顺序显示为三张卡片")
        let threeIDs = threeStore.lastCapturedBatchIDs
        try check(threeIDs == threeStore.rootEntries.map(\.id),
                  "微信批次保存后的项目 ID 没有对应原消息顺序")
        let repairStart = Date()
        let oneMissing = WeChatImageRepairSession.Target(
            id: threeIDs[1], sourcePath: threeStore.rootEntries[1].filePath!, position: 2
        )
        let oneImageSession = WeChatImageRepairSession(
            targets: [oneMissing], changeCount: 100, createdAt: repairStart
        )
        try check(oneImageSession.decision(
            copiedFilePaths: [], newChangeCount: 101,
            now: repairStart.addingTimeInterval(30)
        ) == .automatic(oneMissing), "下一次单独复制的微信图片未匹配唯一缺图卡片")
        try check(oneImageSession.decision(
            copiedFilePaths: ["/different/image.jpg"], newChangeCount: 101,
            now: repairStart.addingTimeInterval(30)
        ) == .confirm([oneMissing]), "图片路径明确不符时不应自动填入占位项")
        try check(oneImageSession.decision(
            copiedFilePaths: [], newChangeCount: 100,
            now: repairStart.addingTimeInterval(30)
        ) == .expired, "没有新复制动作却触发了自动补全")
        try check(oneImageSession.decision(
            copiedFilePaths: [], newChangeCount: 101,
            now: repairStart.addingTimeInterval(180)
        ) == .confirm([oneMissing]), "过了即时复制窗口仍未经确认自动补全")
        try check(oneImageSession.decision(
            copiedFilePaths: [], newChangeCount: 101,
            now: repairStart.addingTimeInterval(601)
        ) == .expired, "过期批次仍被自动关联")
        try threeStore.repairUnavailableImage(id: threeIDs[1], data: jpeg, type: UTType.jpeg.identifier)
        try check(threeStore.rootEntries.map(\.kind) == [.text, .image, .text] &&
                  threeStore.rootEntries.map(\.id) == threeIDs &&
                  threeStore.rootEntries.count == 3,
                  "单独复制图片补全后没有保留原来的三张卡片")

        let protectedItem = NSPasteboardItem()
        let protectedSelection = try JSONSerialization.data(withJSONObject: [
            ["text": "先复制的文字"],
            ["file": protectedFile.path, "text": "图片占位说明"],
            ["file": secondProtectedFile.path, "text": "图片占位说明"]
        ])
        _ = protectedItem.setData(protectedSelection, forType: NSPasteboard.PasteboardType(
            "com.trolltech.anymime.x-xwechat-multiselect-copy"
        ))
        mixedBoard.clearContents()
        try check(mixedBoard.writeObjects([protectedItem]), "无法构造受保护微信图片")
        try check(ClipboardImageCapture.isAppDataContainerURL(protectedFile),
                  "受保护的微信容器图片未识别")
        let protectedCapture = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(protectedCapture.count == 3, "受保护的微信图文没有保留完整顺序")
        guard case .text("先复制的文字") = protectedCapture[0],
              case .unavailableImage(let firstMissing) = protectedCapture[1],
              case .unavailableImage(let secondMissing) = protectedCapture[2],
              firstMissing.path == protectedFile.path,
              secondMissing.path == secondProtectedFile.path else {
            throw WeChatImageTestError.failed("受保护微信图片未明确标记为未保存")
        }
        let protectedStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("ProtectedHistory"), defaults: defaults
        )
        try check(try protectedStore.addCapturedBatch(
            protectedCapture, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            automaticallyGroup: true
        ), "受保护的微信多选未能入库")
        let reloadedProtectedStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("ProtectedHistory"), defaults: defaults
        )
        try check(reloadedProtectedStore.rootEntries.map(\.kind) ==
                  [.text, .unavailableImage, .unavailableImage],
                  "缺图批次仍显示为分组，或分开展示的原始顺序错误")
        guard var protectedGroup = reloadedProtectedStore.entries.first(where: { $0.kind == .group })
        else { throw WeChatImageTestError.failed("不完整批次的成员关系未保存") }
        protectedGroup.groupMembers = protectedGroup.groupMemberIDs.compactMap { id in
            reloadedProtectedStore.entries.first(where: { $0.id == id })
        }
        try check(protectedGroup.groupMembers.map(\.kind) == [.text, .unavailableImage, .unavailableImage],
                  "重启后微信不完整批次的成员丢失")
        try check(ClipboardFilterInventory(entries: reloadedProtectedStore.rootEntries).count(for: .image) == 2,
                  "图片筛选没有显示两张独立的未保存图片")
        let unchangedBoard = NSPasteboard.withUniqueName()
        defer { unchangedBoard.releaseGlobally() }
        unchangedBoard.clearContents()
        _ = unchangedBoard.setString("原有内容", forType: .string)
        try check(!ClipboardPasteboardWriter.write(
            protectedGroup, from: reloadedProtectedStore, to: unchangedBoard
        ), "不完整分组被错误地当作完整图片复制")
        try check(unchangedBoard.string(forType: .string) == "原有内容",
                  "复制不完整分组改写了系统剪贴板")
        try check(ClipboardPasteboardWriter.write(
            protectedGroup.groupMembers[0], from: reloadedProtectedStore, to: unchangedBoard
        ), "组内文字无法单独复制")
        guard let selectedImage = ClipboardImageCapture.captureUserSelectedImage(
            at: secondFile, maximumBytes: 1_000_000
        ) else { throw WeChatImageTestError.failed("用户选择的有效图片无法补全") }
        let originalMemberIDs = protectedGroup.groupMemberIDs
        let firstPlaceholder = protectedGroup.groupMembers[1]
        let secondPlaceholder = protectedGroup.groupMembers[2]
        let twoMissing = WeChatImageRepairSession(
            targets: [
                .init(id: firstPlaceholder.id, sourcePath: firstPlaceholder.filePath!, position: 2),
                .init(id: secondPlaceholder.id, sourcePath: secondPlaceholder.filePath!, position: 3)
            ], changeCount: 200, createdAt: repairStart
        )
        try check(twoMissing.decision(
            copiedFilePaths: [secondPlaceholder.filePath!], newChangeCount: 201,
            now: repairStart.addingTimeInterval(30)
        ) == .automatic(twoMissing.targets[1]), "微信图片路径未精确匹配对应占位项")
        try check(twoMissing.decision(
            copiedFilePaths: [], newChangeCount: 201,
            now: repairStart.addingTimeInterval(30)
        ) == .confirm(twoMissing.targets), "多张缺图时不应猜测图片对应位置")
        try check((try? reloadedProtectedStore.repairUnavailableImage(
            id: firstPlaceholder.id, data: Data(), type: selectedImage.type
        )) == nil, "空图片被写入占位项")
        try check((try? reloadedProtectedStore.repairUnavailableImage(
            id: firstPlaceholder.id, data: Data("invalid".utf8), type: selectedImage.type
        )) == nil, "无效图片被写入占位项")
        try check(reloadedProtectedStore.rootEntries[1].kind == .unavailableImage,
                  "补全失败却修改了原占位项")
        try reloadedProtectedStore.repairUnavailableImage(
            id: firstPlaceholder.id, data: selectedImage.data, type: selectedImage.type
        )
        try check(reloadedProtectedStore.rootEntries.map(\.kind) ==
                  [.text, .image, .unavailableImage],
                  "部分补全后应继续分别显示文字、图片和缺图提示")
        guard var partlyRepaired = reloadedProtectedStore.entries.first(where: { $0.kind == .group })
        else { throw WeChatImageTestError.failed("部分补全后原成员关系丢失") }
        partlyRepaired.groupMembers = partlyRepaired.groupMemberIDs.compactMap { id in
            reloadedProtectedStore.entries.first(where: { $0.id == id })
        }
        guard partlyRepaired.groupMemberIDs == originalMemberIDs,
              partlyRepaired.groupMembers.map(\.kind) == [.text, .image, .unavailableImage],
              partlyRepaired.groupMembers[1].copyCount == firstPlaceholder.copyCount,
              partlyRepaired.groupMembers[1].createdAt == firstPlaceholder.createdAt,
              let repairedURL = reloadedProtectedStore.imageURL(for: partlyRepaired.groupMembers[1]),
              try Data(contentsOf: repairedURL) == jpeg else {
            throw WeChatImageTestError.failed("补全图片没有保留原分组顺序、记录信息或像素")
        }
        try check(!ClipboardPasteboardWriter.write(
            partlyRepaired, from: reloadedProtectedStore, to: unchangedBoard
        ), "仍有缺失图片的分组被错误地当作完整内容复制")
        try reloadedProtectedStore.repairUnavailableImage(
            id: secondPlaceholder.id, data: selectedImage.data, type: selectedImage.type
        )
        let repairedStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("ProtectedHistory"), defaults: defaults
        )
        try check(repairedStore.rootEntries.map(\.kind) == [.text, .image, .image],
                  "全部补全后微信消息仍应逐条显示")
        guard var repairedGroup = repairedStore.entries.first(where: { $0.kind == .group }),
              repairedGroup.groupMemberIDs == originalMemberIDs
        else { throw WeChatImageTestError.failed("重启后补全图片的原成员关系丢失") }
        repairedGroup.groupMembers = repairedGroup.groupMemberIDs.compactMap { id in
            repairedStore.entries.first(where: { $0.id == id })
        }
        guard repairedGroup.groupMembers.count == 3,
              repairedGroup.groupMembers.map(\.kind) == [.text, .image, .image],
              repairedGroup.groupMembers.allSatisfy({ $0.kind != .image || repairedStore.imageURL(for: $0) != nil })
        else { throw WeChatImageTestError.failed("重启后补全的图片或原顺序丢失") }
        try check(ClipboardPasteboardWriter.write(
            repairedGroup, from: repairedStore, to: unchangedBoard
        ), "全部补全后分组仍无法复制")
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: protectedFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: secondProtectedFile.path)
        let authorizedCapture = try ClipboardBatchCapture.capture(
            from: mixedBoard, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            maximumImageBytes: 1_000_000, maximumTextBytes: 1_000_000,
            maximumRichTextBytes: 1_000_000
        )
        try check(authorizedCapture.count == 3,
                  "获得访问权限后没有保存微信图文批次")
        if case .text("先复制的文字") = authorizedCapture[0],
           case .image(let authorizedBytes, _) = authorizedCapture[1],
           case .image = authorizedCapture[2] {
            try check(authorizedBytes == jpeg, "重试后图片内容变化")
        } else {
            throw WeChatImageTestError.failed("授权后图文顺序或类型错误")
        }

        try FileManager.default.removeItem(at: temporaryImage)
        let restored = ClipboardHistoryStore(directory: root.appendingPathComponent("History"), defaults: defaults)
        guard let restoredEntry = restored.entries.first,
              let restoredURL = restored.imageURL(for: restoredEntry),
              let imageSource = CGImageSourceCreateWithURL(restoredURL as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw WeChatImageTestError.failed("原临时文件删除后图片不能预览")
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try check(ClipboardPasteboardWriter.write(restoredEntry, from: restored, to: board),
                  "原临时文件删除后图片不能复制")
        try check(board.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) == jpeg,
                  "回写到剪贴板的 JPEG 内容变化")

        let badFile = root.appendingPathComponent("invalid.jpg")
        try Data("not an image".utf8).write(to: badFile)
        try check(ClipboardImageCapture.captureUserSelectedImage(
            at: badFile, maximumBytes: 1_000_000
        ) == nil, "伪装成图片的本地文件被用于补全")
        try check(ClipboardImageCapture.capture(
            items: [], fileURLs: [badFile], sourceAppName: "微信",
            sourceAppBundleID: nil, maximumBytes: 1_000_000
        ) == nil, "伪装成 JPEG 的普通文件不应存成图片")
        try check(ClipboardImageCapture.capture(
            items: [item], fileURLs: [], sourceAppName: nil,
            sourceAppBundleID: nil, maximumBytes: jpeg.count - 1
        ) == nil, "超过图片大小上限仍被读取")
        print("WeChatImageSmoke passed")
    }

    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw WeChatImageTestError.failed(message) }
    }
}
