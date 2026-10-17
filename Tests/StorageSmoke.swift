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

        let folder = root.appendingPathComponent("fresh")
        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: clock)
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
        try FileManager.default.removeItem(at: imageURL)
        _ = try store.addImage(image, type: "public.png", sourceAppName: "预览", sourceAppBundleID: "app.preview")
        try check(store.entries[0].id == imageEntry.id && (try Data(contentsOf: imageURL)) == image,
                  "重复复制未修复缺失的图片文件")
        try store.delete(imageEntry)
        try check(store.entries.count == 2 && !FileManager.default.fileExists(atPath: imageURL.path), "单条删除未移除图片")
        let codeEntry = store.entries.first { $0.id == firstID }!
        try store.delete(codeEntry)
        try check(store.entries.count == 1, "单条删除未移除文本记录")
        try check(!FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("Content/\(firstID.uuidString).txt").path
        ), "单条删除未移除文本文件")
        let orphanURL = folder.appendingPathComponent("Images/orphan.png")
        try image.write(to: orphanURL)
        let reloaded = ClipboardHistoryStore(directory: folder, defaults: defaults, now: clock)
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
        try check(migrated.errorMessage == nil && migrated.entries.count == 2, "旧 JSON 迁移失败")
        try check(migrated.entries.first(where: { $0.id == legacyTextID })?.text == code, "迁移破坏代码内容")
        try check(migrated.entries.allSatisfy { $0.firstCopiedAt == nil && $0.copyCount == nil }, "迁移编造旧时间或次数")
        _ = try migrated.addText(code, sourceAppName: "新应用", sourceAppBundleID: "app.new")
        try check(migrated.entries.first(where: { $0.id == legacyTextID })?.copyCount == nil,
                  "旧记录再次复制后编造了历史总次数")
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
        do {
            _ = try migratedAgain.addText("另一个进程", sourceAppName: nil)
            throw StorageTestError.failed("检测到旧版索引后仍允许继续写入")
        } catch ClipboardHistoryStoreError.legacyWriterDetected { }

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

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw StorageTestError.failed(message) }
    }

    private static func digest(_ data: Data, prefix: String) -> String {
        SHA256.hash(data: Data(prefix.utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
}
