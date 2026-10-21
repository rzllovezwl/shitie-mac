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
        try check(mixedStore.rootEntries.count == 1 &&
                  mixedStore.rootEntries[0].kind == .group &&
                  mixedStore.rootEntries[0].groupMembers.map(\.kind) == [.image, .text],
                  "微信图文没有显示为包含两项的分组")

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
            automaticallyGroup: true
        ), "微信多选图片和文字未保存")
        try check(multiStore.rootEntries.first?.groupMembers.map(\.kind) == [.image, .image, .text],
                  "微信多选图片和文字未显示为三项分组")

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
            automaticallyGroup: true
        ), "微信实际多选格式未能保存")
        try check(actualStore.rootEntries.first?.groupMembers.map(\.kind) == [.image, .image, .text],
                  "微信实际多选格式未形成三项分组")

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
        guard let protectedGroup = reloadedProtectedStore.rootEntries.first,
              protectedGroup.groupMembers.map(\.kind) == [.text, .unavailableImage, .unavailableImage]
        else { throw WeChatImageTestError.failed("重启后微信不完整分组丢失") }
        try check(ClipboardFilter.image.matches(protectedGroup),
                  "未保存图片的分组没有出现在图片筛选中")
        try check(ClipboardFilterInventory(entries: [protectedGroup]).count(for: .image) == 1,
                  "图片筛选数量未包含不完整分组")
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
