import AppKit
import Foundation
import SQLite3

private enum ClipboardBatchTestError: Error { case failed(String) }

@main
struct ClipboardBatchSmoke {
    @MainActor
    static func main() async throws {
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
        let temporarySource = root.appendingPathComponent("微信临时文件.xlsx")
        try Data("file contents".utf8).write(to: temporarySource)
        let recoveryStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("recovery"), defaults: defaults
        )
        try check(try recoveryStore.addFileReference(temporarySource, sourceAppName: "微信"),
                  "临时文件引用未保存")
        let staleEntry = recoveryStore.rootEntries[0]
        try FileManager.default.removeItem(at: temporarySource)
        let beforeFailedWrite = destinationBoard.changeCount
        try check(!ClipboardPasteboardWriter.write(staleEntry, from: recoveryStore,
                                                  to: destinationBoard),
                  "原文件不存在时不应清空剪贴板")
        try check(destinationBoard.changeCount == beforeFailedWrite,
                  "失效文件复制失败时不应替换系统剪贴板")
        let replacementFolder = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementFolder,
                                                withIntermediateDirectories: true)
        let replacement = replacementFolder.appendingPathComponent("微信临时文件.xlsx")
        try Data("file contents".utf8).write(to: replacement)
        try recoveryStore.relinkFileReference(staleEntry, to: replacement)
        let recoveredEntry = recoveryStore.rootEntries[0]
        try check(!recoveryStore.fileHasSavedCopy(recoveredEntry)
                  && recoveredEntry.filePath == replacement.path,
                  "重新选择文件后应只保存引用，不保存文件副本")
        try check(ClipboardPasteboardWriter.write(recoveredEntry, from: recoveryStore,
                                                  to: destinationBoard),
                  "恢复文件后仍无法复制")
        try check(try capture(destinationBoard).count == 1,
                  "恢复的文件未写入剪贴板")
        try await recoveryStore.saveFileCopy(for: recoveredEntry)
        let withManualCopy = recoveryStore.rootEntries[0]
        try check(recoveryStore.fileHasSavedCopy(withManualCopy), "手动保存副本失败")
        try FileManager.default.removeItem(at: replacement)
        do {
            try recoveryStore.removeSavedFileCopy(for: withManualCopy)
            throw ClipboardBatchTestError.failed("原文件不可用时不应删除唯一的副本")
        } catch ClipboardHistoryStoreError.fileReferenceUnavailable {
            try check(recoveryStore.fileHasSavedCopy(recoveryStore.rootEntries[0]),
                      "移除失败后应保留副本")
        }
        try Data("file contents".utf8).write(to: replacement)
        try recoveryStore.removeSavedFileCopy(for: withManualCopy)
        let withoutManualCopy = recoveryStore.rootEntries[0]
        try check(!recoveryStore.fileHasSavedCopy(withoutManualCopy)
                  && ClipboardPasteboardWriter.write(withoutManualCopy, from: recoveryStore,
                                                    to: destinationBoard),
                  "移除副本后应仍能使用原文件引用")
        let bookmarkSource = root.appendingPathComponent("bookmark-refresh.txt")
        try Data("bookmark".utf8).write(to: bookmarkSource)
        let bookmarkStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("bookmark-refresh"), defaults: defaults
        )
        try check(try bookmarkStore.addFileReference(bookmarkSource, sourceAppName: "微信"),
                  "文件书签未保存")
        let originalBookmarkEntry = bookmarkStore.rootEntries[0]
        guard let bookmarkName = originalBookmarkEntry.fileBookmarkName else {
            throw ClipboardBatchTestError.failed("文件书签未创建")
        }
        let bookmarkURL = root.appendingPathComponent("bookmark-refresh/Bookmarks/\(bookmarkName)")
        try Data("stale bookmark".utf8).write(to: bookmarkURL, options: .atomic)
        try check(try bookmarkStore.addFileReference(bookmarkSource, sourceAppName: "微信"),
                  "重新复制同一文件失败")
        try check(bookmarkStore.rootEntries[0].id == originalBookmarkEntry.id &&
                  (try Data(contentsOf: bookmarkURL)) != Data("stale bookmark".utf8),
                  "重新复制同一文件应刷新旧书签")
        let nativeBoard = NSPasteboard.withUniqueName()
        defer { nativeBoard.releaseGlobally() }
        let nativeItem = NSPasteboardItem()
        try check(nativeItem.setString(bookmarkSource.absoluteString, forType: .fileURL)
                  && nativeItem.setData(Data(), forType: NSPasteboard.PasteboardType(
                    "com.trolltech.anymime.text--uri-list"
                  )), "无法构造微信原始文件剪贴板")
        nativeBoard.clearContents()
        try check(nativeBoard.writeObjects([nativeItem]), "无法写入微信原始文件剪贴板")
        let beforeNativeReuse = nativeBoard.changeCount
        try check(ClipboardPasteboardWriter.canReuseOriginalWeChatFile(
                    [bookmarkStore.rootEntries[0]], on: nativeBoard
                  ) && nativeBoard.changeCount == beforeNativeReuse,
                  "微信文件仍在原剪贴板时应保留其访问交接")
        guard let nativeDrag = ClipboardPasteboardWriter.dragPayload(
            [bookmarkStore.rootEntries[0]], from: bookmarkStore
        ) else { throw ClipboardBatchTestError.failed("当前微信文件不能开始拖动") }
        try check(nativeDrag.writers.count == 1
                  && nativeDrag.writers[0] is NSURL
                  && nativeDrag.fileAccesses.count == 1,
                  "可读取的微信文件拖动应保留源文件访问")
        destinationBoard.clearContents()
        try check(destinationBoard.writeObjects(nativeDrag.writers),
                  "微信文件拖动未写入独立剪贴板")
        let draggedFiles = try capture(destinationBoard)
        try check(draggedFiles.count == 1 && nativeBoard.changeCount == beforeNativeReuse,
                  "微信文件拖动应写入独立剪贴板而不改变当前复制内容")
        nativeBoard.clearContents()
        try check(nativeBoard.writeObjects([bookmarkSource as NSURL]),
                  "无法构造已改写的文件剪贴板")
        try check(!ClipboardPasteboardWriter.canReuseOriginalWeChatFile(
                    [bookmarkStore.rootEntries[0]], on: nativeBoard
                  ), "改写后的文件 URL 不应误认为微信原始剪贴板")
        let weChatTemporaryFile = root.appendingPathComponent(
            "Library/Containers/com.tencent.xinWeChat/Data/temp/RWTemp/session/file.fit"
        )
        try FileManager.default.createDirectory(
            at: weChatTemporaryFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("fit".utf8).write(to: weChatTemporaryFile)
        let weChatBoard = NSPasteboard.withUniqueName()
        defer { weChatBoard.releaseGlobally() }
        weChatBoard.clearContents()
        try check(weChatBoard.writeObjects([weChatTemporaryFile as NSURL]),
                  "无法构造微信临时文件剪贴板")
        let weChatFiles = try capture(weChatBoard, sourceAppName: "微信")
        try check(try bookmarkStore.addCapturedBatch(
            weChatFiles, sourceAppName: "微信", sourceAppBundleID: "com.tencent.xinWeChat",
            automaticallyGroup: true
        ),
                  "微信临时文件引用未保存")
        let weChatTemporaryEntry = bookmarkStore.rootEntries[0]
        let expectedWeChatFolder = weChatTemporaryFile.deletingLastPathComponent()
            .deletingLastPathComponent()
        try check(bookmarkStore.suggestedWeChatFolder(for: weChatTemporaryEntry)
                  == expectedWeChatFolder,
                  "微信临时文件应建议授权稳定的文件夹")
        try bookmarkStore.authorizeWeChatFolder(expectedWeChatFolder,
                                                for: weChatTemporaryEntry)
        let permissionStore = ClipboardHistoryStore(
            directory: root.appendingPathComponent("bookmark-refresh"), defaults: defaults
        )
        try check(permissionStore.filePasteboardAccess(for: weChatTemporaryEntry) != nil
                  && !permissionStore.fileHasSavedCopy(weChatTemporaryEntry),
                  "微信文件夹授权重启后应可用且不保存文件副本")
        weChatBoard.clearContents()
        try check(weChatBoard.setString("later text", forType: .string),
                  "无法切换微信原剪贴板")
        try check(bookmarkStore.filePasteboardAccess(for: weChatTemporaryEntry) != nil
                  && ClipboardPasteboardWriter.write(
                    weChatTemporaryEntry, from: bookmarkStore, to: destinationBoard
                  ), "仍可访问的微信临时文件应能从历史复制")
        try check(ClipboardPasteboardWriter.dragPayload(
                    [weChatTemporaryEntry], from: bookmarkStore
                  )?.writers.count == 1,
                  "仍可访问的微信临时文件应能从历史拖动")
        try await bookmarkStore.saveFileCopy(for: weChatTemporaryEntry)
        let temporaryWithCopy = bookmarkStore.rootEntries[0]
        try check(bookmarkStore.fileHasSavedCopy(temporaryWithCopy),
                  "测试所需的微信临时文件副本未创建")
        try bookmarkStore.removeSavedFileCopy(for: temporaryWithCopy)
        try check(!bookmarkStore.fileHasSavedCopy(bookmarkStore.rootEntries[0])
                  && bookmarkStore.filePasteboardAccess(for: bookmarkStore.rootEntries[0]) != nil,
                  "微信原文件仍可访问时应能移除先前保存的副本")
        try FileManager.default.removeItem(at: weChatTemporaryFile)
        let beforeTemporaryWrite = destinationBoard.changeCount
        try check(bookmarkStore.filePasteboardAccess(for: weChatTemporaryEntry) == nil
                  && !ClipboardPasteboardWriter.write(
                    weChatTemporaryEntry, from: bookmarkStore, to: destinationBoard
                  ) && destinationBoard.changeCount == beforeTemporaryWrite,
                  "微信临时文件失效后不可改写为死文件 URL")
        try check(ClipboardPasteboardWriter.dragPayload(
                    [weChatTemporaryEntry], from: bookmarkStore
                  ) == nil, "微信临时文件失效后不可开始无效拖动")
        let largeFile = root.appendingPathComponent("large-sparse-file.bin")
        try Data().write(to: largeFile)
        let largeFileHandle = try FileHandle(forWritingTo: largeFile)
        try largeFileHandle.truncate(atOffset: 3 * 1_024 * 1_024 * 1_024)
        try largeFileHandle.close()
        let beforeLargeReference = bookmarkStore.activeStorageBytes
        try check(try bookmarkStore.addFileReference(largeFile, sourceAppName: "微信"),
                  "大文件位置引用未保存")
        try check(bookmarkStore.rootEntries[0].byteCount > 2_000_000_000 &&
                  bookmarkStore.rootEntries[0].fileCopyName == nil &&
                  bookmarkStore.activeStorageBytes - beforeLargeReference < 1_000_000,
                  "大文件位置引用不应复制文件内容到历史目录")
        let staleLarge = root.appendingPathComponent("stale-large-file.bin")
        try Data().write(to: staleLarge)
        try check(try bookmarkStore.addFileReference(staleLarge, sourceAppName: "微信"),
                  "待恢复的大文件引用未保存")
        let staleLargeEntry = bookmarkStore.rootEntries[0]
        guard let staleBookmarkName = staleLargeEntry.fileBookmarkName else {
            throw ClipboardBatchTestError.failed("待恢复文件缺少书签")
        }
        let staleBookmarkData = try Data(contentsOf: root.appendingPathComponent(
            "bookmark-refresh/Bookmarks/\(staleBookmarkName)"
        ))
        try FileManager.default.removeItem(at: staleLarge)
        let beforeLargeRelink = bookmarkStore.activeStorageBytes
        try bookmarkStore.relinkFileReference(staleLargeEntry, to: largeFile)
        try check(bookmarkStore.rootEntries[0].fileCopyName == nil &&
                  bookmarkStore.rootEntries[0].digest != staleLargeEntry.digest &&
                  bookmarkStore.activeStorageBytes - beforeLargeRelink < 1_000_000,
                  "重新关联大文件不应保存文件内容副本")
        let relinkedLarge = bookmarkStore.rootEntries[0]
        guard let relinkedBookmarkName = relinkedLarge.fileBookmarkName else {
            throw ClipboardBatchTestError.failed("重新关联后缺少书签")
        }
        // Simulate a record written by an older build: the card points to the
        // new location but its bookmark still resolves to the old one.
        try Data().write(to: staleLarge)
        try staleBookmarkData.write(to: root.appendingPathComponent(
            "bookmark-refresh/Bookmarks/\(relinkedBookmarkName)"
        ), options: .atomic)
        try check(bookmarkStore.filePasteboardAccess(for: relinkedLarge)?.url.path == largeFile.path,
                  "旧书签不应覆盖卡片明确记录的文件位置")
        try check(try bookmarkStore.addFileReference(staleLarge, sourceAppName: "微信"),
                  "重新复制旧路径失败")
        try check(bookmarkStore.entries.contains(where: {
            $0.id == relinkedLarge.id && $0.filePath == largeFile.path
        }) && bookmarkStore.entries.contains(where: {
            $0.id != relinkedLarge.id && $0.filePath == staleLarge.path
        }), "旧路径重新复制不应覆盖已重新关联的卡片")

        // Reproduce the persisted state of builds before 151, where relinking
        // changed the card path but left its digest and bookmark at the old
        // WeChat location. The next copy must create a new card, not rewrite
        // the relinked one.
        let legacySource = root.appendingPathComponent("legacy/WeChat/file.fit")
        let legacyTarget = root.appendingPathComponent("legacy/Downloads/file.fit")
        try FileManager.default.createDirectory(at: legacySource.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyTarget.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("fit".utf8).write(to: legacySource)
        try Data("fit".utf8).write(to: legacyTarget)
        let legacyDirectory = root.appendingPathComponent("legacy/history")
        let legacyID: UUID
        do {
            let originalStore = ClipboardHistoryStore(directory: legacyDirectory, defaults: defaults)
            try check(try originalStore.addFileReference(legacySource, sourceAppName: "微信"),
                      "旧版文件记录未创建")
            legacyID = originalStore.rootEntries[0].id
        }
        var legacyDB: OpaquePointer?
        try check(sqlite3_open(legacyDirectory.appendingPathComponent("history.sqlite").path,
                               &legacyDB) == SQLITE_OK, "无法打开旧版测试数据库")
        let legacySQL = "UPDATE history_entries SET file_path = '\(legacyTarget.path)' "
            + "WHERE id = '\(legacyID.uuidString)'"
        let legacyUpdate = sqlite3_exec(legacyDB, legacySQL, nil, nil, nil)
        sqlite3_close(legacyDB)
        try check(legacyUpdate == SQLITE_OK, "无法模拟旧版路径与书签错位")
        let migratedLegacy = ClipboardHistoryStore(directory: legacyDirectory, defaults: defaults)
        let mismatchedEntry = migratedLegacy.rootEntries[0]
        try check(migratedLegacy.filePasteboardAccess(for: mismatchedEntry)?.url.path == legacyTarget.path,
                  "加载旧版错位卡片时应以记录路径为准")
        try check(try migratedLegacy.addFileReference(legacySource, sourceAppName: "微信"),
                  "重新复制旧微信路径失败")
        try check(migratedLegacy.rootEntries.count == 2 &&
                  migratedLegacy.entries.contains(where: {
                      $0.id == legacyID && $0.filePath == legacyTarget.path
                  }) && migratedLegacy.entries.contains(where: {
                      $0.id != legacyID && $0.filePath == legacySource.path
                  }), "旧版错位卡片不应吞掉新的微信文件")
        let restrictedFile = root.appendingPathComponent("unreadable-file.json")
        try Data("{}".utf8).write(to: restrictedFile)
        try check(try bookmarkStore.addFileReference(restrictedFile, sourceAppName: "微信"),
                  "受限文件引用未保存")
        let restrictedEntry = bookmarkStore.rootEntries[0]
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restrictedFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: restrictedFile.path) }
        try check(bookmarkStore.filePreviewAccess(for: restrictedEntry) == nil,
                  "不可读文件不应进入预览")
        let beforeRestrictedWrite = destinationBoard.changeCount
        try check(!ClipboardPasteboardWriter.write(restrictedEntry, from: bookmarkStore,
                                                   to: destinationBoard)
                  && destinationBoard.changeCount == beforeRestrictedWrite,
                  "不可读文件不能改写为无法供目标应用粘贴的 URL")
        try check(ClipboardPasteboardWriter.dragPayload([restrictedEntry],
                                                        from: bookmarkStore) == nil,
                  "不可读文件不能启动看似成功的拖动")
        guard let fileDrag = ClipboardPasteboardWriter.dragPayload([group], from: fileStore) else {
            throw ClipboardBatchTestError.failed("整组文件不能开始拖放")
        }
        try check(fileDrag.writers.count == 2 && fileDrag.fileAccesses.count == 2,
                  "拖放时文件数量或访问权限不完整")
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
        try check(ClipboardPasteboardWriter.write(
            textGroup.groupMembers[0], from: textStore, to: destinationBoard, mode: .plainText
        ) && destinationBoard.string(forType: .string) == "第一段" &&
                  destinationBoard.data(forType: .rtf) == nil,
                  "复制纯文本时不应保留富文本格式")
        guard let textDrag = ClipboardPasteboardWriter.dragPayload([textGroup], from: textStore) else {
            throw ClipboardBatchTestError.failed("整组文字不能开始拖放")
        }
        let dragBoard = NSPasteboard.withUniqueName()
        defer { dragBoard.releaseGlobally() }
        try check(dragBoard.writeObjects(textDrag.writers) &&
                  dragBoard.string(forType: .string) == "第一段\n\n第二段",
                  "整组文字拖放没有提供完整内容")
        try textStore.delete(textGroup.groupMembers[0])
        try check(textStore.rootEntries.count == 1 && textStore.rootEntries[0].kind != .group,
                  "成员删除后单成员组未解散")

        let officeBoard = NSPasteboard.withUniqueName()
        defer { officeBoard.releaseGlobally() }
        let officeItem = NSPasteboardItem()
        let officeRTF = Data("{\\rtf1\\ansi Office text}".utf8)
        _ = officeItem.setString("Office text", forType: .string)
        _ = officeItem.setData(
            officeRTF, forType: NSPasteboard.PasteboardType("com.trolltech.anymime.text--rtf")
        )
        officeBoard.clearContents()
        try check(officeBoard.writeObjects([officeItem]), "无法构造 WPS 富文本剪贴板")
        let officeCaptured = try capture(officeBoard)
        guard officeCaptured.count == 1,
              case .richText(let officeText, let capturedRTF, _, _) = officeCaptured[0],
              officeText == "Office text", capturedRTF == officeRTF else {
            throw ClipboardBatchTestError.failed("WPS 专有 RTF 未随文字一起保存")
        }
        let officeStore = ClipboardHistoryStore(directory: root.appendingPathComponent("office"), defaults: defaults)
        _ = try officeStore.addCapturedBatch(
            officeCaptured, sourceAppName: "WPS Office", sourceAppBundleID: nil,
            automaticallyGroup: true
        )
        try check(officeStore.rootEntries.count == 1 &&
                  officeStore.rootEntries[0].hasRichText &&
                  officeStore.richTextData(for: officeStore.rootEntries[0]).rtf == officeRTF,
                  "WPS 图文记录被拆分，或内嵌 RTF 未持久保存")

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

        let manualFolder = root.appendingPathComponent("manual-group")
        let manualStore = ClipboardHistoryStore(directory: manualFolder, defaults: defaults)
        for value in ["甲", "乙", "丙", "丁"] {
            _ = try manualStore.addText(value, sourceAppName: "笔记")
        }
        let manualByText = Dictionary(uniqueKeysWithValues: manualStore.entries.compactMap {
            entry in entry.text.map { ($0, entry.id) }
        })
        func manualID(_ text: String) throws -> UUID {
            guard let id = manualByText[text] else {
                throw ClipboardBatchTestError.failed("缺少手动分组测试记录：\(text)")
            }
            return id
        }
        let firstManualGroupID = try manualStore.groupSelection(
            memberIDs: [manualID("甲"), manualID("乙"), manualID("丙")]
        )
        try check(firstManualGroupID != nil &&
                  manualStore.rootEntries.first?.groupMembers.map(\.text) == ["甲", "乙", "丙"],
                  "手动成组未保留所选顺序")
        let secondManualGroupID = try manualStore.groupSelection(
            memberIDs: [manualID("乙"), manualID("丁")]
        )
        try check(secondManualGroupID != nil &&
                  manualStore.rootEntries.filter { $0.kind == .group }.count == 2,
                  "重组后应同时保留原组的剩余成员和新组")
        try check(manualStore.rootEntries.first(where: { $0.id == firstManualGroupID })?
                  .groupMembers.map(\.text) == ["甲", "丙"] &&
                  manualStore.rootEntries.first(where: { $0.id == secondManualGroupID })?
                  .groupMembers.map(\.text) == ["乙", "丁"],
                  "移出旧组时成员关系不正确")
        let manualReload = ClipboardHistoryStore(directory: manualFolder, defaults: defaults)
        try check(manualReload.rootEntries.filter { $0.kind == .group }.count == 2,
                  "手动分组未持久保存")
        try check(try manualReload.ungroupSelection(groupIDs: [secondManualGroupID!]),
                  "取消手动分组失败")
        try check(manualReload.rootEntries.first(where: { $0.id == firstManualGroupID })?
                  .groupMembers.map(\.text) == ["甲", "丙"] &&
                  manualReload.rootEntries.filter { $0.kind == .text }.compactMap(\.text).sorted() == ["丁", "乙"],
                  "取消成组不应删除成员或影响其他分组")

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
           case .fileReference(let mixedURL, _) = mixedCaptured[1] {
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

        let imageStore = ClipboardHistoryStore(directory: root.appendingPathComponent("images"), defaults: defaults)
        let firstImage = try pngPixel(red: 255, green: 0)
        let secondImage = try pngPixel(red: 0, green: 255)
        _ = try imageStore.addImage(firstImage, type: "public.png", sourceAppName: "iPhone 截图")
        let firstImageEntry = imageStore.entries[0]
        _ = try imageStore.addImage(secondImage, type: "public.png", sourceAppName: "iPhone 截图")
        let secondImageEntry = imageStore.entries[0]
        try check(try imageStore.recordBatchCopy(
            of: [firstImageEntry.id, secondImageEntry.id], automaticallyGroup: true
        ), "两张图片未成组")
        let imageGroup = imageStore.rootEntries[0]
        try check(ClipboardPasteboardWriter.write(imageGroup, from: imageStore, to: destinationBoard),
                  "两张图片无法回写剪贴板")
        let imageItems = destinationBoard.pasteboardItems ?? []
        try check(imageItems.count == 2 &&
                  imageItems[0].data(forType: .png) == firstImage &&
                  imageItems[1].data(forType: .png) == secondImage,
                  "两张图片的内容或顺序丢失")
        let imageURLs = (destinationBoard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []).map { $0 as URL }
        guard let savedFirstImage = imageStore.imageURL(for: firstImageEntry),
              let savedSecondImage = imageStore.imageURL(for: secondImageEntry) else {
            throw ClipboardBatchTestError.failed("成组图片没有保存到磁盘")
        }
        try check(imageURLs == [savedFirstImage, savedSecondImage],
                  "两张图片未提供可供目标应用批量读取的文件 URL")
        let generalBoardChangeCount = NSPasteboard.general.changeCount
        guard let imageDrag = ClipboardPasteboardWriter.dragPayload([imageGroup], from: imageStore) else {
            throw ClipboardBatchTestError.failed("两张图片不能开始拖放")
        }
        try check(imageDrag.writers.count == 2 &&
                  NSPasteboard.general.changeCount == generalBoardChangeCount,
                  "构造拖放内容时修改了系统剪贴板")
        dragBoard.clearContents()
        try check(dragBoard.writeObjects(imageDrag.writers), "两张图片无法写入拖放剪贴板")
        let draggedImages = dragBoard.pasteboardItems ?? []
        try check(draggedImages.count == 2 &&
                  draggedImages[0].data(forType: .png) == firstImage &&
                  draggedImages[1].data(forType: .png) == secondImage,
                  "两张图片的拖放数据或顺序错误")

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
                               "DROP TABLE history_record_times; ALTER TABLE history_entries DROP COLUMN text_revision; ALTER TABLE history_entries DROP COLUMN screenshot_origin; DROP TABLE history_group_members; ALTER TABLE history_entries DROP COLUMN is_favorite; PRAGMA user_version = 2",
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

    private static func capture(
        _ board: NSPasteboard, sourceAppName: String = "访达"
    ) throws -> [ClipboardCapturedItem] {
        try ClipboardBatchCapture.capture(
            from: board, sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppName == "微信" ? "com.tencent.xinWeChat" : "com.apple.finder",
            maximumImageBytes: 15 * 1_024 * 1_024,
            maximumTextBytes: 32 * 1_024 * 1_024,
            maximumRichTextBytes: 15 * 1_024 * 1_024
        )
    }

    private static func pngPixel(red: CGFloat, green: CGFloat) throws -> Data {
        guard let image = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        ) else {
            throw ClipboardBatchTestError.failed("无法生成图片测试数据")
        }
        image.setColor(NSColor(calibratedRed: red / 255, green: green / 255,
                               blue: 0, alpha: 1), atX: 0, y: 0)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw ClipboardBatchTestError.failed("无法编码图片测试数据")
        }
        return data
    }

    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ClipboardBatchTestError.failed(message) }
    }
}
