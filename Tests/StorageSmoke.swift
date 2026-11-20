import CryptoKit
import Foundation

private enum StorageTestError: Error { case failed(String) }

private struct LegacyFixture: Encodable {
    let id: UUID
    let createdAt: Date
    let kind: String
    let text: String?
    let imageFileName: String?
    let imagePasteboardType: String?
    let digest: String
    let byteCount: Int
    let sourceAppName: String?
}

@main
struct StorageSmoke {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookStage0-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ClipHoookStage0-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw StorageTestError.failed("无法建立隔离设置") }
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = { now }

        try checkScreenshotEditTransactions(root: root, defaults: defaults, now: clock)
        try checkGroupedCapacityPruning(root: root)

        let folder = root.appendingPathComponent("fresh")
        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: clock)
        try check(store.isNewInstallation, "新建资料库应标记为首次安装")
        let code = "    func main() {\n\tprint(\"hello\")\n    }\n\n"
        try check(try store.addText(code, sourceAppName: "编辑器", sourceAppBundleID: "app.editor"), "保存代码失败")
        let firstID = store.entries[0].id
        let firstDate = store.entries[0].firstCopiedAt
        now.addTimeInterval(20)
        _ = try store.addText("第二条", sourceAppName: "浏览器", sourceAppBundleID: "app.browser")
        now.addTimeInterval(20)
        _ = try store.addText(code, sourceAppName: "浏览器", sourceAppBundleID: "app.browser")
        try check(store.entries.count == 2 && store.entries[0].id == firstID, "去重或排序失败")
        try check(store.entries[0].copyCount == 2 && store.entries[0].firstCopiedAt == firstDate, "复制次数或首次时间失败")
        try check(store.entries[0].sourceAppBundleID == "app.browser", "来源 Bundle ID 未更新")
        try check(store.entries[0].text == code, "代码缩进和换行改变")
        let codeURL = folder.appendingPathComponent("Content/\(firstID.uuidString).txt")
        try FileManager.default.removeItem(at: codeURL)
        _ = try store.addText(code, sourceAppName: "编辑器", sourceAppBundleID: "app.editor")
        try check((try String(contentsOf: codeURL, encoding: .utf8)) == code,
                  "重复复制未修复缺失的文本文件")

        let image = Data(repeating: 0x89, count: 4096)
        _ = try store.addImage(image, type: "public.png", sourceAppName: "预览", sourceAppBundleID: "app.preview")
        let imageEntry = store.entries[0]
        let imageURL = store.imageURL(for: imageEntry)!
        try check((try Data(contentsOf: imageURL)) == image, "图片内容丢失")
        let editBase = Data("original screenshot".utf8)
        let editDocument = Data("{\"version\":1}".utf8)
        try store.saveScreenshotEditData(base: editBase, document: editDocument, for: imageEntry)
        try check(store.screenshotEditData(for: imageEntry)?.base == editBase &&
                  store.screenshotEditData(for: imageEntry)?.document == editDocument,
                  "可编辑标注数据未随图片卡片保存")
        let ocrSignature = store.ocrSourceSignature(for: imageEntry)!
        try store.saveOCRText("只在本机保存的识别文字 ZX-2048", for: imageEntry,
                              expectedSourceSignature: ocrSignature)
        let ocrURL = folder.appendingPathComponent("OCR/\(imageEntry.id.uuidString).json")
        try check(store.entries[0].ocrText?.contains("ZX-2048") == true &&
                  FileManager.default.fileExists(atPath: ocrURL.path),
                  "识别文字缓存未随图片记录保存")
        let ocrReloaded = ClipboardHistoryStore(directory: folder, defaults: defaults, now: clock)
        try check(ocrReloaded.entries.first(where: { $0.id == imageEntry.id })?.ocrText?.contains("ZX-2048") == true,
                  "重新启动后应恢复已识别的图片文字")
        try check(ocrReloaded.screenshotEditData(for: imageEntry)?.base == editBase &&
                  ocrReloaded.screenshotEditData(for: imageEntry)?.document == editDocument,
                  "重新启动后应恢复可编辑标注")
        try FileManager.default.removeItem(at: imageURL)
        _ = try store.addImage(image, type: "public.png", sourceAppName: "预览", sourceAppBundleID: "app.preview")
        try check(store.entries[0].id == imageEntry.id && (try Data(contentsOf: imageURL)) == image,
                  "重复复制未修复缺失的图片文件")
        let copiesBeforeImport = store.entries[0].copyCount
        try check(try store.importPhoneScreenshot(image, type: "public.png"),
                  "iPhone 上传与 Mac 已有图片相同时应更新来源")
        try check(store.entries[0].id == imageEntry.id &&
                  store.entries[0].sourceAppName == "iPhone 截图" &&
                  store.entries[0].sourceAppBundleID == nil,
                  "相同图片应保留原卡片并显示 iPhone 来源")
        try check(store.entries[0].copyCount == copiesBeforeImport,
                  "重复送达的 iPhone 截图不应增加复制次数")
        try check(try !store.importPhoneScreenshot(image, type: "public.png"),
                  "重复上传同一张 iPhone 截图不应再次更新")
        let phoneImage = Data(repeating: 0x52, count: 4096)
        try check(try store.importPhoneScreenshot(phoneImage, type: "public.png"),
                  "新的 iPhone 截图保存失败")
        try check(store.entries[0].sourceAppName == "iPhone 截图" &&
                  store.entries[0].copyCount == nil &&
                  (try Data(contentsOf: store.imageURL(for: store.entries[0])!)) == phoneImage,
                  "iPhone 截图来源、次数或图片内容不正确")
        try store.delete(store.entries[0])
        try store.delete(imageEntry)
        try check(store.entries.count == 2 && !FileManager.default.fileExists(atPath: imageURL.path), "单条删除未移除图片")
        try check(!FileManager.default.fileExists(atPath: ocrURL.path), "删除图片后仍留有识别文字缓存")
        try check(store.screenshotEditData(for: imageEntry) == nil,
                  "删除图片后应清理对应的可编辑标注")
        let codeEntry = store.entries.first { $0.id == firstID }!
        try store.delete(codeEntry)
        try check(store.entries.count == 1, "单条删除未移除文本记录")
        try check(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("Content/\(firstID.uuidString).txt").path
        ), "单条删除未移除文本文件")
        let orphanURL = folder.appendingPathComponent("Images/orphan.png")
        try image.write(to: orphanURL)
        let reloaded = ClipboardHistoryStore(directory: folder, defaults: defaults, now: clock)
        try check(!reloaded.isNewInstallation, "已有资料库重新启动不应触发首次引导")
        try check(reloaded.entries.count == 1 && reloaded.entries[0].text == "第二条", "重启恢复失败")
        let recoveredURL = folder.appendingPathComponent("UnreferencedRecovery/Images/orphan.png")
        try check(!FileManager.default.fileExists(atPath: orphanURL.path)
                  && (try Data(contentsOf: recoveredURL)) == image,
                  "未关联文件没有安全移入恢复目录")
        try reloaded.clear()
        try check(reloaded.entries.isEmpty, "清空后仍有记录")
        try check(reloaded.recoveryBytes > 0, "清空历史错误删除了恢复文件")
        try reloaded.removeRecoveryFiles()
        try check(reloaded.recoveryBytes == 0, "手动删除恢复文件失败")

        let reuseFolder = root.appendingPathComponent("manual-copy")
        let reuseStore = ClipboardHistoryStore(directory: reuseFolder, defaults: defaults, now: clock)
        _ = try reuseStore.addText("较早的记录", sourceAppName: "编辑器", sourceAppBundleID: "app.editor")
        let reusedEntry = reuseStore.entries[0]
        now.addTimeInterval(20)
        _ = try reuseStore.addText("最新记录", sourceAppName: "浏览器", sourceAppBundleID: "app.browser")
        try check(try reuseStore.recordCopy(of: reusedEntry.id), "仅复制后未更新历史记录")
        try check(reuseStore.entries[0].id == reusedEntry.id &&
                  reuseStore.entries[0].copyCount == 2 &&
                  reuseStore.entries[0].firstCopiedAt == reusedEntry.firstCopiedAt &&
                  reuseStore.entries[0].sourceAppBundleID == "app.editor" &&
                  reuseStore.entries[0].createdAt > reuseStore.entries[1].createdAt,
                  "仅复制应将原记录置顶、增加次数并保留来源")
        let reusedAfterRestart = ClipboardHistoryStore(directory: reuseFolder, defaults: defaults, now: clock)
        try check(reusedAfterRestart.entries[0].id == reusedEntry.id &&
                  reusedAfterRestart.entries[0].copyCount == 2,
                  "仅复制后的置顶和次数未持久保存")
        try check(try !reuseStore.recordCopy(of: UUID()), "不存在的记录不应生成复制次数")

        // Create a byte-for-byte fixture of the old JSON + Images layout.
        let legacyFolder = root.appendingPathComponent("legacy")
        let legacyImages = legacyFolder.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: legacyImages, withIntermediateDirectories: true)
        let legacyTextID = UUID()
        let legacyImageID = UUID()
        let legacyImageName = "\(legacyImageID.uuidString).png"
        try image.write(to: legacyImages.appendingPathComponent(legacyImageName))
        let fixtures = [
            LegacyFixture(id: legacyTextID, createdAt: now, kind: "text", text: code,
                          imageFileName: nil, imagePasteboardType: nil, digest: digest(Data(code.utf8), prefix: "text"),
                          byteCount: code.utf8.count, sourceAppName: "Xcode"),
            LegacyFixture(id: legacyImageID, createdAt: now, kind: "image", text: nil,
                          imageFileName: legacyImageName, imagePasteboardType: "public.png",
                          digest: digest(image, prefix: "image"), byteCount: image.count, sourceAppName: "预览")
        ]
        let oldJSON = try JSONEncoder().encode(fixtures)
        try oldJSON.write(to: legacyFolder.appendingPathComponent("history.json"))
        let migrated = ClipboardHistoryStore(directory: legacyFolder, defaults: defaults, now: clock)
        try check(!migrated.isNewInstallation, "旧版 JSON 资料库迁移时不应触发首次引导")
        try check(migrated.errorMessage == nil && migrated.entries.count == 2, "旧 JSON 迁移失败")
        try check(migrated.entries.first(where: { $0.id == legacyTextID })?.text == code, "迁移破坏代码内容")
        try check(migrated.entries.allSatisfy { $0.firstCopiedAt == nil && $0.copyCount == nil }, "迁移编造旧时间或次数")
        _ = try migrated.addText(code, sourceAppName: "新应用", sourceAppBundleID: "app.new")
        try check(migrated.entries.first(where: { $0.id == legacyTextID })?.copyCount == nil,
                  "旧记录再次复制后编造了历史总次数")
        let legacySource = migrated.entries.first(where: { $0.id == legacyTextID })?.sourceAppName
        try check(try migrated.recordCopy(of: legacyTextID), "旧记录仅复制未被计入")
        try check(migrated.entries[0].id == legacyTextID &&
                  migrated.entries[0].copyCount == 1 &&
                  migrated.entries[0].firstCopiedAt == nil &&
                  migrated.entries[0].sourceAppName == legacySource,
                  "旧记录应从已知次数开始统计，不能编造首次复制时间或来源")
        now.addTimeInterval(20)
        _ = try migrated.addText(code, sourceAppName: "新应用", sourceAppBundleID: "app.new")
        try check(migrated.entries[0].copyCount == 2,
                  "旧记录开始统计后，再次复制应继续增加次数")
        let backup = legacyFolder.appendingPathComponent("LegacyMigrationBackup")
        try check((try Data(contentsOf: backup.appendingPathComponent("history.json"))) == oldJSON,
                  "迁移备份缺少旧 JSON")
        try check((try Data(contentsOf: backup.appendingPathComponent("Images/\(legacyImageName)"))) == image,
                  "迁移备份缺少旧图片")
        try check(!FileManager.default.fileExists(atPath: legacyFolder.appendingPathComponent("history.json").path),
                  "迁移后旧索引仍会导致历史分叉")
        let migratedAgain = ClipboardHistoryStore(directory: legacyFolder, defaults: defaults, now: clock)
        try check(migratedAgain.entries.count == 2, "迁移不具备幂等性：\(migratedAgain.entries.count)，\(migratedAgain.errorMessage ?? "无错误")")
        try migratedAgain.clear()
        try check(migratedAgain.entries.isEmpty && migratedAgain.migrationBackupBytes > 0,
                  "清空历史错误删除了可回退备份")
        try oldJSON.write(to: legacyFolder.appendingPathComponent("history.json"))
        let conflictingOldBuild = ClipboardHistoryStore(directory: legacyFolder, defaults: defaults, now: clock)
        try check(conflictingOldBuild.errorMessage != nil, "旧版重建 JSON 后没有检测到双写风险")
        try check(conflictingOldBuild.entries.isEmpty,
                  "已清空的 SQLite 历史不能被旧 JSON 中的记录重新替代")
        do {
            _ = try migratedAgain.addText("另一个进程", sourceAppName: nil)
            throw StorageTestError.failed("检测到旧版索引后仍允许继续写入")
        } catch ClipboardHistoryStoreError.legacyWriterDetected { }

        let conflictFolder = root.appendingPathComponent("downgrade-conflict")
        let originalHistory = ClipboardHistoryStore(directory: conflictFolder, defaults: defaults, now: clock)
        _ = try originalHistory.addText(code, sourceAppName: nil)
        _ = try originalHistory.addImage(image, type: "public.png", sourceAppName: nil)
        let originalIDs = Set(originalHistory.entries.map(\.id))
        let downgraded = LegacyFixture(
            id: UUID(), createdAt: now, kind: "text", text: "old build's only record",
            imageFileName: nil, imagePasteboardType: nil, digest: "legacy-only",
            byteCount: 23, sourceAppName: nil)
        let downgradedJSON = try JSONEncoder().encode([downgraded])
        let conflictIndex = conflictFolder.appendingPathComponent("history.json")
        try downgradedJSON.write(to: conflictIndex)
        let conflictedHistory = ClipboardHistoryStore(directory: conflictFolder, defaults: defaults, now: clock)
        try check(conflictedHistory.errorMessage != nil &&
                  Set(conflictedHistory.entries.map(\.id)) == originalIDs &&
                  conflictedHistory.entries.first(where: { $0.kind == .text })?.text == code,
                  "降级冲突时应保留完整数据库历史供查看，不能只显示旧版的一条记录")
        do {
            _ = try conflictedHistory.addImage(Data([1, 2, 3]), type: "public.png", sourceAppName: nil)
            throw StorageTestError.failed("降级冲突时仍允许截图写入")
        } catch ClipboardHistoryStoreError.legacyWriterDetected { }
        try check((try Data(contentsOf: conflictIndex)) == downgradedJSON,
                  "只读显示不应删除或覆盖旧版索引")
        try FileManager.default.moveItem(at: conflictIndex,
            to: conflictFolder.appendingPathComponent("preserved-history.json"))
        let recoveredHistory = ClipboardHistoryStore(directory: conflictFolder, defaults: defaults, now: clock)
        try check(recoveredHistory.errorMessage == nil &&
                  Set(recoveredHistory.entries.map(\.id)) == originalIDs,
                  "归档冲突索引并重启后应恢复原历史")
        try check(try recoveredHistory.addImage(Data([1, 2, 3]), type: "public.png", sourceAppName: nil),
                  "解除冲突后截图写入应恢复")

        let brokenFolder = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        let brokenFixture = LegacyFixture(id: UUID(), createdAt: now, kind: "image", text: nil,
            imageFileName: "missing.png", imagePasteboardType: "public.png", digest: "broken",
            byteCount: 200, sourceAppName: nil)
        let brokenJSON = try JSONEncoder().encode([brokenFixture])
        try brokenJSON.write(to: brokenFolder.appendingPathComponent("history.json"))
        let broken = ClipboardHistoryStore(directory: brokenFolder, defaults: defaults, now: clock)
        try check(broken.errorMessage != nil, "不完整历史没有报告迁移失败")
        do {
            _ = try broken.addText("should fail", sourceAppName: nil)
            throw StorageTestError.failed("迁移失败后仍允许写入")
        } catch ClipboardHistoryStoreError.unavailable { }
        try check((try Data(contentsOf: brokenFolder.appendingPathComponent("history.json"))) == brokenJSON,
                  "迁移失败破坏旧索引")

        defaults.set(HistoryRetention.forever.rawValue, forKey: HistoryStoragePolicy.retentionKey)
        let limitFolder = root.appendingPathComponent("limit")
        let limited = ClipboardHistoryStore(directory: limitFolder, defaults: defaults, now: clock)
        _ = try limited.addImage(Data(repeating: 0x50, count: 600_000), type: "public.png", sourceAppName: nil)
        let oldestURL = limited.imageURL(for: limited.entries[0])!
        now.addTimeInterval(1)
        _ = try limited.addImage(Data(repeating: 0x51, count: 600_000), type: "public.png", sourceAppName: nil)
        let beforeLimitBytes = limited.activeStorageBytes
        try check(beforeLimitBytes > 1_024 * 1_024, "实际磁盘占用未计入图片和数据库")
        defaults.set(1, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        try check(try limited.applyStoragePolicy(), "设置空间上限没有触发清理")
        try check(limited.entries.count == 1 && !FileManager.default.fileExists(atPath: oldestURL.path),
                  "空间超限未先删除最早记录")
        try check(limited.activeStorageBytes <= 1_024 * 1_024, "清理后实际占用仍超上限")

        let fiveHundredMB: Int64 = 500 * 1_024 * 1_024
        try check(HistoryStorageReminder.nextLevel(
            actualBytes: fiveHundredMB - 1, maximumBytes: nil, lastNotifiedLevel: 0
        ) == nil, "存储提醒过早出现")
        try check(HistoryStorageReminder.nextLevel(
            actualBytes: fiveHundredMB, maximumBytes: nil, lastNotifiedLevel: 0
        ) == 1, "未限制时跨过 500 MB 应提醒一次")
        try check(HistoryStorageReminder.nextLevel(
            actualBytes: fiveHundredMB, maximumBytes: nil, lastNotifiedLevel: 1
        ) == nil, "同一存储量不应重复提醒")
        try check(HistoryStorageReminder.nextLevel(
            actualBytes: 6 * 1_024 * 1_024 * 1_024,
            maximumBytes: nil, lastNotifiedLevel: 1
        ) == 3, "跨过更高档位应再次提醒")
        try check(HistoryStorageReminder.nextLevel(
            actualBytes: fiveHundredMB, maximumBytes: 1_024 * 1_024 * 1_024,
            lastNotifiedLevel: 0
        ) == nil, "已设置存储上限不应提醒")

        defaults.set(HistoryRetention.oneDay.rawValue, forKey: HistoryStoragePolicy.retentionKey)
        now.addTimeInterval(2 * 24 * 60 * 60)
        try check(try limited.applyStoragePolicy() && limited.entries.isEmpty, "按时间清理失败")

        let excluded = [ExcludedApplication(bundleIdentifier: "app.secret", name: "秘密应用")]
        RecordingExclusionPolicy.save(excluded, in: defaults)
        try check(RecordingExclusionPolicy.applications(in: defaults) == excluded, "排除应用设置未保存")
        try check(!RecordingExclusionPolicy.shouldRecord(sourceBundleID: "app.secret", foregroundChangedSinceLastPoll: false, excluded: excluded), "排除应用仍被记录")
        try check(!RecordingExclusionPolicy.shouldRecord(sourceBundleID: "app.other", foregroundChangedSinceLastPoll: true, excluded: excluded), "来源不明的切换间隔仍被记录")
        try check(!RecordingExclusionPolicy.shouldRecord(sourceBundleID: nil, foregroundChangedSinceLastPoll: false, excluded: excluded), "来源未知时仍被记录")
        try check(RecordingExclusionPolicy.shouldRecord(sourceBundleID: "app.other", foregroundChangedSinceLastPoll: false, excluded: excluded), "其他应用被错误排除")
        defaults.set(Data("not-json".utf8), forKey: RecordingExclusionPolicy.preferenceKey)
        try check(!RecordingExclusionPolicy.configurationIsValid(in: defaults), "损坏的排除设置未触发停止记录")
        print("Stage 0 storage smoke test passed")
    }

    @MainActor
    private static func checkGroupedCapacityPruning(root: URL) throws {
        let manager = FileManager.default
        let suite = "ClipHoookCapacity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("forever", forKey: HistoryStoragePolicy.retentionKey)
        defaults.set(0, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = root.appendingPathComponent("grouped-capacity")
        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { date })
        func addImage(_ byte: UInt8) throws -> ClipboardEntry {
            date.addTimeInterval(1)
            _ = try store.addImage(Data(repeating: byte, count: 300_000), type: "public.png", sourceAppName: nil)
            let entry = store.entries[0]
            try store.saveScreenshotEditData(base: Data(repeating: byte, count: 150_000),
                                             document: Data(repeating: byte, count: 100_000), for: entry)
            return entry
        }
        let first = try addImage(0x41)
        let second = try addImage(0x42)
        date.addTimeInterval(1)
        _ = try store.groupSelection(memberIDs: [first.id, second.id])
        let latest = try addImage(0x43)
        defaults.set(1, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        try check(try store.applyStoragePolicy(), "容量超限时应清理旧记录")
        try check(store.entries.map(\.id) == [latest.id] && store.activeStorageBytes <= 1_024 * 1_024,
                  "删除分组后应继续按原顺序清理释放的成员，并计入新格式标注文件")
        try check(store.screenshotEditData(for: latest)?.base.count == 150_000 &&
                  store.screenshotEditData(for: first) == nil && store.screenshotEditData(for: second) == nil,
                  "容量扣减应与实际删除的标注文件一致，且保留最新图片")
        let orphan = folder.appendingPathComponent("Content/orphan.txt")
        try Data(repeating: 0x44, count: 600_000).write(to: orphan)
        _ = try store.applyStoragePolicy()
        try check(store.entries.map(\.id) == [latest.id] &&
                  !manager.fileExists(atPath: orphan.path) && store.recoveryBytes > 0 &&
                  store.activeStorageBytes <= 1_024 * 1_024,
                  "应先恢复未关联文件，重新核算容量后不能多删历史")
        let reopened = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { date })
        try check(reopened.entries.map(\.id) == [latest.id] &&
                  reopened.screenshotEditData(for: latest)?.document.count == 100_000,
                  "批量清理后重启应保留图片及其可编辑标注")
    }

    @MainActor
    private static func checkScreenshotEditTransactions(root: URL, defaults: UserDefaults,
                                                         now: @escaping () -> Date) throws {
        let manager = FileManager.default
        let folder = root.appendingPathComponent("editable-transactions")
        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: now)
        _ = try store.addImage(Data([1, 2, 3, 4]), type: "public.png", sourceAppName: "Test")
        let entry = store.entries[0]
        let annotations = folder.appendingPathComponent("ScreenshotAnnotations")
        let legacyBaseURL = folder.appendingPathComponent("ScreenshotBases/\(entry.id).image")
        let legacyDocumentURL = annotations.appendingPathComponent("\(entry.id).json")
        let recordURL = annotations.appendingPathComponent("\(entry.id).plist")
        let base = Data("existing editable base".utf8)
        let document = Data("existing editable annotations".utf8)
        try base.write(to: legacyBaseURL)
        try document.write(to: legacyDocumentURL)
        try check(store.screenshotEditData(for: entry)?.base == base &&
                  store.screenshotEditData(for: entry)?.document == document,
                  "旧版双文件标注仍应可以打开")

        func rejectWrite() throws {
            try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: annotations.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: annotations.path) }
            var failed = false
            do {
                try store.saveScreenshotEditData(base: Data("replacement base".utf8),
                                                 document: Data("replacement annotations".utf8), for: entry)
            } catch { failed = true }
            try check(failed, "只读目录应拒绝标注保存")
            try check(store.screenshotEditData(for: entry)?.base == base &&
                      store.screenshotEditData(for: entry)?.document == document,
                      "保存失败不能删除底图、混用新旧标注或损坏已有版本")
        }
        try rejectWrite()
        try check((try Data(contentsOf: legacyBaseURL)) == base &&
                  (try Data(contentsOf: legacyDocumentURL)) == document,
                  "新格式保存失败必须完整保留旧格式标注")

        try store.saveScreenshotEditData(base: base, document: document, for: entry)
        try check(manager.fileExists(atPath: recordURL.path) &&
                  !manager.fileExists(atPath: legacyBaseURL.path) &&
                  !manager.fileExists(atPath: legacyDocumentURL.path),
                  "完整保存后应移除旧的双文件，避免重复占用空间")
        try rejectWrite()
        let reopened = ClipboardHistoryStore(directory: folder, defaults: defaults, now: now)
        try check(reopened.screenshotEditData(for: entry)?.base == base &&
                  reopened.screenshotEditData(for: entry)?.document == document,
                  "失败后重启仍应读取上一份完整标注")
        let newBase = Data("new base".utf8)
        let newDocument = Data("new annotations".utf8)
        try reopened.saveScreenshotEditData(base: newBase, document: newDocument, for: entry)
        let replaced = ClipboardHistoryStore(directory: folder, defaults: defaults, now: now)
        try check(replaced.screenshotEditData(for: entry)?.base == newBase &&
                  replaced.screenshotEditData(for: entry)?.document == newDocument,
                  "成功覆盖后重启应读取匹配的新底图和标注")
        try replaced.delete(entry)
        try check(!manager.fileExists(atPath: recordURL.path), "删除图片应一并删除新格式标注文件")
        print("Screenshot edit transaction smoke passed: legacy reads, failed initial save, failed replacement, restart, replacement and deletion")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw StorageTestError.failed(message) }
    }

    private static func digest(_ data: Data, prefix: String) -> String {
        SHA256.hash(data: Data(prefix.utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
}
