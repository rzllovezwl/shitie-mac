import AppKit
import Foundation

@main
struct PinnedImageSmoke {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookPinnedSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let imageURL = root.appendingPathComponent("original.png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                bytesPerRow: 8, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let png = NSBitmapImageRep(cgImage: context.makeImage()!)
            .representation(using: .png, properties: [:])!
        try png.write(to: imageURL)

        let pinDirectory = root.appendingPathComponent("PinnedImages", isDirectory: true)
        let store = try PinnedImageStore(directory: pinDirectory)
        let sourceID = UUID()
        let screenshotFrame = NSRect(x: 100, y: 180, width: 320, height: 240)
        let pin = try store.add(sourceEntryID: sourceID, sourceURL: imageURL,
                                title: "测试图片", initialContentFrame: screenshotFrame)
        precondition(pin.frame?.rect.insetBy(dx: PinnedImageRecord.shadowInset,
                                              dy: PinnedImageRecord.shadowInset) == screenshotFrame,
                     "截图贴图的图片内容应覆盖原选区，而不是窗口阴影覆盖原选区")
        precondition(pin.allSpaces, "新贴图应默认出现在所有桌面和全屏应用")
        precondition(store.count == 1 && store.storageBytes == Int64(png.count),
                     "贴图用量只应统计图片副本")
        precondition(pin.displayOpacity == 1, "新贴图应完全不透明")
        let duplicate = try store.add(sourceEntryID: sourceID, sourceURL: imageURL,
                                      title: "测试图片")
        precondition(duplicate.id == pin.id, "重复钉住不应创建副本")
        let frame = NSRect(x: 123, y: 456, width: 520, height: 410)
        try store.updateFrame(frame, for: pin.id)
        try store.updateOpacity(0, for: pin.id)
        precondition(store.record(for: sourceID)?.displayOpacity == 0.1,
                     "透明度下限应让贴图保持可见")
        try store.updateOpacity(2, for: pin.id)
        precondition(store.record(for: sourceID)?.displayOpacity == 1,
                     "透明度上限不能超过完全不透明")
        try store.updateOpacity(0.45, for: pin.id)
        try store.setAllSpaces(true, for: pin.id)
        try FileManager.default.removeItem(at: imageURL)

        let restored = try PinnedImageStore(directory: pinDirectory)
        let restoredPin = restored.record(for: sourceID)!
        precondition(restoredPin.frame?.rect == frame && restoredPin.allSpaces &&
                     restoredPin.displayOpacity == 0.45,
                     "重启后位置、透明度或所有桌面设置丢失")
        try restored.setAllSpaces(false, for: pin.id)
        let manualChoice = try PinnedImageStore(directory: pinDirectory)
        precondition(manualChoice.record(for: sourceID)?.allSpaces == false,
                     "用户选择仅当前桌面后，重启不应再次迁移")
        let restoredData = try Data(contentsOf: restored.imageURL(for: restoredPin)!)
        precondition(restoredData == png,
                     "原图片移走后贴图副本不应丢失")
        try restored.remove(pin.id)
        precondition(restored.count == 0 && restored.imageURL(for: pin) == nil,
                     "取消钉住应移除副本")

        let target = root.appendingPathComponent("symlink-target.png")
        let link = root.appendingPathComponent("symlink.png")
        try png.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedPin = try restored.add(sourceEntryID: UUID(), sourceURL: link,
                                         title: "符号链接图片")
        try FileManager.default.removeItem(at: target)
        let linkedSnapshot = restored.imageURL(for: linkedPin)!
        let linkedBytes = try Data(contentsOf: linkedSnapshot)
        precondition(linkedBytes == png,
                     "贴图副本不能保留指向原文件的符号链接")
        try restored.remove(linkedPin.id)

        let stackImageURL = root.appendingPathComponent("stack.png")
        try png.write(to: stackImageURL)
        let stackDirectory = root.appendingPathComponent("StackedPins", isDirectory: true)
        let stack = try PinnedImageStore(directory: stackDirectory)
        let back = try stack.add(sourceEntryID: UUID(), sourceURL: stackImageURL,
                                 title: "先钉住")
        let middle = try stack.add(sourceEntryID: UUID(), sourceURL: stackImageURL,
                                   title: "第二张")
        let front = try stack.add(sourceEntryID: UUID(), sourceURL: stackImageURL,
                                  title: "最后钉住")
        precondition(stack.records.map(\.id) == [back.id, middle.id, front.id],
                     "新贴图应按钉住顺序从后到前排列")
        try stack.bringToFront(back.id)
        precondition(stack.records.map(\.id) == [middle.id, front.id, back.id],
                     "点击底层贴图应只把它移到顶层")
        try stack.bringToFront(back.id)
        precondition(stack.records.map(\.id) == [middle.id, front.id, back.id],
                     "重复点击顶层贴图不应改变其余顺序")
        let stackedAfterRestart = try PinnedImageStore(directory: stackDirectory)
        precondition(stackedAfterRestart.records.map(\.id) == [middle.id, front.id, back.id],
                     "点击确认的贴图顺序应在重启后保留")

        let legacy = root.appendingPathComponent("LegacyPins", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacyID = UUID()
        let legacyRecord = PinnedImageRecord(
            id: legacyID, sourceEntryID: UUID(), fileName: "\(legacyID.uuidString).png",
            title: "旧贴图", frame: nil, allSpaces: false
        )
        try JSONEncoder().encode([legacyRecord]).write(
            to: legacy.appendingPathComponent("pins.json"))
        try png.write(to: legacy.appendingPathComponent(legacyRecord.fileName))
        let migrated = try PinnedImageStore(directory: legacy)
        precondition(migrated.records.first?.allSpaces == true,
                     "已有贴图首次升级后应能进入全屏应用")
        precondition(migrated.records.first?.displayOpacity == 1,
                     "旧贴图缺少透明度字段时应保持完全不透明")
        try migrated.setAllSpaces(false, for: legacyID)
        let migratedAgain = try PinnedImageStore(directory: legacy)
        precondition(migratedAgain.records.first?.allSpaces == false,
                     "升级后手动切回当前桌面应保持")

        let invalid = root.appendingPathComponent("BrokenPins", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        let marker = invalid.appendingPathComponent("leave-this-file.png")
        try png.write(to: marker)
        try Data("invalid json".utf8).write(to: invalid.appendingPathComponent("pins.json"))
        do {
            _ = try PinnedImageStore(directory: invalid)
            preconditionFailure("损坏索引不应被当成空贴图覆盖")
        } catch PinnedImageError.unreadableIndex {
            precondition(FileManager.default.fileExists(atPath: marker.path),
                         "读取损坏索引不能删除用户贴图文件")
        }
        print("Pinned image smoke test passed")
    }
}
