import AppKit
import Foundation
import SQLite3

private enum ClipboardBatchTestError: Error { case failed(String) }

@main
struct ClipboardBatchSmoke {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookBatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ClipHoookBatch-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw ClipboardBatchTestError.failed("无法创建隔离设置")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HistoryRetention.forever.rawValue, forKey: HistoryStoragePolicy.retentionKey)
        try check(ClipboardGroupingPreference.isEnabled(in: defaults), "自动成组应默认开启")

        let firstFile = root.appendingPathComponent("first.txt")
        let secondFile = root.appendingPathComponent("second.txt")
        try Data("1".utf8).write(to: firstFile)
        try Data("2".utf8).write(to: secondFile)
        let sourceBoard = NSPasteboard.withUniqueName()
        defer { sourceBoard.releaseGlobally() }
        sourceBoard.clearContents()
        try check(sourceBoard.writeObjects([firstFile as NSURL, secondFile as NSURL]),
                  "无法构造外部多文件剪贴板")
        let files = try capture(sourceBoard)
        try check(files.count == 2, "一次多文件复制未识别为两个项目")

        let fileFolder = root.appendingPathComponent("files")
        let fileStore = ClipboardHistoryStore(directory: fileFolder, defaults: defaults)
        try check(try fileStore.addCapturedBatch(files, sourceAppName: "访达",
                                                  sourceAppBundleID: "com.apple.finder",
                                                  automaticallyGroup: true), "多文件保存失败")
        try check(fileStore.rootEntries.count == 1, "多文件未折叠为一张卡片")
        let group = fileStore.rootEntries[0]
        try check(group.kind == .group && group.groupMembers.map(\.fileName) == ["first.txt", "second.txt"],
                  "分组成员顺序或内容错误")
        let fileInventory = ClipboardFilterInventory(entries: fileStore.rootEntries)
        try check(fileInventory.count(for: .all) == 1 && fileInventory.count(for: .files) == 1 &&
                  fileInventory.matching(fileStore.rootEntries, filter: .files, query: "second.txt").count == 1,
                  "分组未按成员参与分类和搜索")
        try check(group.sourceAppName == "访达" && group.copyCount == 1, "分组来源或次数错误")
        let destinationBoard = NSPasteboard.withUniqueName()
        defer { destinationBoard.releaseGlobally() }
        try check(ClipboardPasteboardWriter.write(group, from: fileStore, to: destinationBoard),
                  "整组文件无法回写剪贴板")
        try check(try capture(destinationBoard).count == 2, "整组文件回写后缺少项目")
        _ = try fileStore.addCapturedBatch(files, sourceAppName: "访达",
                                           sourceAppBundleID: "com.apple.finder",
                                           automaticallyGroup: true)
        try check(fileStore.rootEntries.count == 1 &&
                  fileStore.rootEntries[0].id == group.id &&
                  fileStore.rootEntries[0].copyCount == 2,
                  "重复批次应复用原组并增加次数")
        let reopened = ClipboardHistoryStore(directory: fileFolder, defaults: defaults)
        try check(reopened.rootEntries.count == 1 &&
                  reopened.rootEntries[0].groupMembers.map(\.fileName) == ["first.txt", "second.txt"],
                  "重启后分组成员和顺序未恢复")
        try reopened.delete(reopened.rootEntries[0])
        try check(reopened.rootEntries.count == 2 && reopened.rootEntries.allSatisfy { $0.kind == .fileReference },
                  "删除分组后成员应恢复为独立记录")

        let textBoard = NSPasteboard.withUniqueName()
        defer { textBoard.releaseGlobally() }
        let first = NSPasteboardItem()
        _ = first.setString("第一段", forType: .string)
        _ = first.setData(Data("{\\rtf1\\ansi first}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        _ = second.setString("第二段", forType: .string)
        textBoard.clearContents()
        try check(textBoard.writeObjects([first, second]), "无法构造多文字剪贴板")
        let texts = try capture(textBoard)
        try check(texts.count == 2, "多格式单项被误算为多个项目")
        let textStore = ClipboardHistoryStore(directory: root.appendingPathComponent("texts"), defaults: defaults)
        _ = try textStore.addCapturedBatch(texts, sourceAppName: "编辑器",
                                           sourceAppBundleID: "app.editor", automaticallyGroup: true)
        let textGroup = textStore.rootEntries[0]
        try check(textGroup.kind == .group && textGroup.groupMembers.count == 2,
                  "多文字未成组")
        let textInventory = ClipboardFilterInventory(entries: textStore.rootEntries)
        try check(textInventory.count(for: .richText) == 1 &&
                  textInventory.count(for: .plainText) == 1,
                  "不同文字类型的成员未参与分类")
        try check(ClipboardPasteboardWriter.write(textGroup, from: textStore, to: destinationBoard),
                  "整组文字无法复制")
        try check(destinationBoard.string(forType: .string) == "第一段\n\n第二段",
                  "多文字复制顺序或分隔符错误")
        try textStore.delete(textGroup.groupMembers[0])
        try check(textStore.rootEntries.count == 1 && textStore.rootEntries[0].kind != .group,
                  "成员删除后单成员组未解散")

        let panelStore = ClipboardHistoryStore(directory: root.appendingPathComponent("panel"), defaults: defaults)
        _ = try panelStore.addText("面板一", sourceAppName: "笔记")
        let panelFirst = panelStore.entries[0]
        _ = try panelStore.addText("面板二", sourceAppName: "笔记")
        let panelSecond = panelStore.entries[0]
        try check(try panelStore.recordBatchCopy(
            of: [panelFirst.id, panelSecond.id], automaticallyGroup: true
        ), "面板多选复制未记录")
        try check(panelStore.rootEntries.count == 1 &&
                  panelStore.rootEntries[0].groupMembers.map(\.text) == ["面板一", "面板二"],
                  "面板多选未按所选顺序成组")
        let panelGroup = panelStore.rootEntries[0]
        _ = try panelStore.recordBatchCopy(
            of: [panelFirst.id, panelSecond.id], automaticallyGroup: true
        )
        try check(panelStore.rootEntries[0].id == panelGroup.id &&
                  panelStore.rootEntries[0].copyCount == 2,
                  "重复多选未更新原组次数")
        _ = try panelStore.recordBatchCopy(
            of: [panelFirst.id, panelSecond.id], automaticallyGroup: false
        )
        try check(panelStore.rootEntries.prefix(2).map(\.kind) == [.text, .text],
                  "关闭自动成组后多选项目未独立置顶")

        let mixedStore = ClipboardHistoryStore(directory: root.appendingPathComponent("mixed"), defaults: defaults)
        _ = try mixedStore.addCapturedBatch([.text("说明"), .fileReference(firstFile)],
                                            sourceAppName: nil, sourceAppBundleID: nil,
                                            automaticallyGroup: true)
        let mixedGroup = mixedStore.rootEntries[0]
        try check(ClipboardPasteboardWriter.write(mixedGroup, from: mixedStore, to: destinationBoard),
                  "混合分组无法写入剪贴板")
        try check(destinationBoard.pasteboardItems?.count == 2,
                  "混合分组回写后缺少剪贴板项目")
        let mixedCaptured = try capture(destinationBoard)
        try check(mixedCaptured.count == 2, "外部混合复制漏掉了文件或文字")
        if case .text("说明") = mixedCaptured[0],
           case .fileReference(let mixedURL) = mixedCaptured[1] {
            try check(mixedURL.standardizedFileURL == firstFile.standardizedFileURL,
                      "外部混合复制的文件顺序错误")
        } else {
            throw ClipboardBatchTestError.failed("外部混合复制的项目顺序或类型错误")
        }

        let repeatedStore = ClipboardHistoryStore(directory: root.appendingPathComponent("repeated"), defaults: defaults)
        _ = try repeatedStore.addCapturedBatch([.text("相同"), .text("相同")],
                                               sourceAppName: nil, sourceAppBundleID: nil,
                                               automaticallyGroup: true)
        try check(repeatedStore.rootEntries.count == 1 &&
                  repeatedStore.rootEntries[0].groupMembers.map(\.text) == ["相同", "相同"],
                  "相同内容的两个剪贴板项目被错误折叠成单项")
        let repeatedReload = ClipboardHistoryStore(directory: root.appendingPathComponent("repeated"), defaults: defaults)
        try check(repeatedReload.rootEntries[0].groupMembers.count == 2,
                  "重复成员的顺序未持久保存")

        let migrationFolder = root.appendingPathComponent("migration")
        do {
            let oldStore = ClipboardHistoryStore(directory: migrationFolder, defaults: defaults)
            _ = try oldStore.addText("旧记录", sourceAppName: "旧应用")
        }
        var handle: OpaquePointer?
        let databasePath = migrationFolder.appendingPathComponent("history.sqlite").path
        try check(sqlite3_open(databasePath, &handle) == SQLITE_OK, "无法建立旧数据库测试夹具")
        defer { if let handle { sqlite3_close(handle) } }
        try check(sqlite3_exec(handle,
                               "DROP TABLE history_group_members; PRAGMA user_version = 2",
                               nil, nil, nil) == SQLITE_OK,
                  "无法模拟旧版数据库")
        sqlite3_close(handle)
        handle = nil
        let migratedStore = ClipboardHistoryStore(directory: migrationFolder, defaults: defaults)
        try check(migratedStore.errorMessage == nil && migratedStore.rootEntries.first?.text == "旧记录",
                  "版本 2 数据库迁移破坏旧记录")
        _ = try migratedStore.addCapturedBatch([.text("新一"), .text("新二")],
                                               sourceAppName: nil, sourceAppBundleID: nil,
                                               automaticallyGroup: true)
        try check(migratedStore.rootEntries.first?.kind == .group,
                  "迁移后无法保存分组")

        let ungrouped = ClipboardHistoryStore(directory: root.appendingPathComponent("ungrouped"), defaults: defaults)
        _ = try ungrouped.addCapturedBatch([.text("A"), .text("B")], sourceAppName: nil,
                                           sourceAppBundleID: nil, automaticallyGroup: false)
        try check(ungrouped.rootEntries.map(\.text) == ["A", "B"], "关闭自动成组后顺序错误")
        let rollback = ClipboardHistoryStore(directory: root.appendingPathComponent("rollback"), defaults: defaults)
        do {
            _ = try rollback.addCapturedBatch([.text(""), .text("valid")], sourceAppName: nil,
                                              sourceAppBundleID: nil, automaticallyGroup: true)
            throw ClipboardBatchTestError.failed("不完整批次被保存")
        } catch ClipboardHistoryStoreError.invalidBatch { }
        try check(rollback.entries.isEmpty, "失败批次留下半组记录")
        try check((try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("rollback/Content"),
            includingPropertiesForKeys: nil)).isEmpty, "失败批次留下内容文件")
        print("ClipboardBatchSmoke passed")
    }

    private static func capture(_ board: NSPasteboard) throws -> [ClipboardCapturedItem] {
        try ClipboardBatchCapture.capture(
            from: board, sourceAppName: "访达", sourceAppBundleID: "com.apple.finder",
            maximumImageBytes: 15 * 1_024 * 1_024,
            maximumTextBytes: 32 * 1_024 * 1_024,
            maximumRichTextBytes: 15 * 1_024 * 1_024
        )
    }

    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ClipboardBatchTestError.failed(message) }
    }
}
