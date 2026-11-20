import AppKit
import SQLite3

@main
struct ClipboardCalendarSmoke {
    enum Failure: Error { case failed(String) }

    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipHoookCalendar-\(UUID())")
        let suite = "ClipHoookCalendar-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("forever", forKey: HistoryStoragePolicy.retentionKey)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let d1 = date("2026-10-01T08:00:00+08:00")
        let d2 = date("2026-10-02T08:00:00+08:00")
        let d3 = date("2026-10-03T08:00:00+08:00")
        let d4 = date("2026-10-04T08:00:00+08:00")
        let d5 = date("2026-10-05T08:00:00+08:00")
        var now = d1
        let folder = root.appendingPathComponent("history")
        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now }, calendar: calendar)
        try check(store.errorMessage == nil, "无法创建日历资料库")
        _ = try store.addText("alpha note", sourceAppName: "Notes")
        let textID = store.entries[0].id
        now = d3
        _ = try store.addText("alpha note", sourceAppName: "Notes")
        _ = try store.addText("alpha note", sourceAppName: "Notes")
        try check(store.entries.count == 1 && store.entries[0].copyCount == 3, "重复复制应共用内容文件")
        let inventory = ClipboardFilterInventory(entries: store.rootEntries)
        let counts = inventory.dailyCounts(store.rootEntries, filter: .all, query: "", calendar: calendar)
        try check(counts[calendar.startOfDay(for: d1)] == 1 && counts[calendar.startOfDay(for: d3)] == 1 &&
                  counts[calendar.startOfDay(for: d2)] == nil, "已知日期缺失或虚构了中间日期")
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Content").path)
        try check(contents.count == 1, "按日期记录不得重复保存文本内容")

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        now = d2
        _ = try store.addImage(png, type: "public.png", sourceAppName: "Safari",
                               sourceAppBundleID: "com.apple.Safari", screenshotOrigin: .cliphoook)
        let imageID = store.entries.first { $0.kind == .image }!.id
        var image = store.entries.first { $0.id == imageID }!
        try check(ClipboardFilter.cliphoookScreenshot.matches(image) && ClipboardFilter.image.matches(image) &&
                  image.sourceAppName == "Safari", "截图渠道不得替换实际来源应用")
        // Copy/paste round-trip uses an isolated pasteboard, not the user's.
        let board = NSPasteboard(name: NSPasteboard.Name("ClipHoookCalendar-\(UUID())"))
        defer { board.releaseGlobally() }
        try check(ClipboardPasteboardWriter.write(image, from: store, to: board), "截图写入测试剪贴板失败")
        let captured = try ClipboardBatchCapture.capture(from: board, sourceAppName: "Preview", sourceAppBundleID: nil,
            maximumImageBytes: store.maximumImageBytes, maximumTextBytes: store.maximumTextBytes,
            maximumRichTextBytes: store.maximumRichTextBytes)
        if case .image(_, _, let origin) = captured.first {
            try check(origin == .cliphoook, "重新捕获丢失截图分类")
        } else { throw Failure.failed("测试截图未被识别为图片") }
        let unmarked = NSPasteboardItem()
        unmarked.setData(png, forType: .png)
        try check(ClipboardScreenshotMetadata.origin(in: unmarked) == nil,
                  "普通 PNG 不应仅因格式被识别为截屏")
        unmarked.setData(Data("metadata".utf8), forType: ClipboardScreenshotMetadata.systemMetadataType)
        try check(ClipboardScreenshotMetadata.origin(in: unmarked) == .screen,
                  "系统截图的显式剪贴板元数据应被识别")
        try check(ClipboardScreenshotMetadata.origin(in: nil, sourceBundleID: "com.apple.screencaptureui") == .screen,
                  "系统截图应用未被识别")
        let screenFile = root.appendingPathComponent("screen.png")
        try png.write(to: screenFile)
        _ = try store.addFileReference(screenFile, sourceAppName: "Finder", screenshotOrigin: .screen)
        let file = store.entries.first { $0.kind == .fileReference }!
        try check(ClipboardFilter.screenScreenshot.matches(file) && ClipboardFilter.files.matches(file) &&
                  ClipboardFilter.image.matches(file), "截图文件应同时属于文件、图片和屏幕截屏")

        now = d4
        let screenshots = try store.saveFavoriteCategory(name: "截图", tint: .blue, icon: .image,
                                                         editing: nil, collecting: [imageID])
        _ = try store.setScreenshotOrigin(.ordinaryImage, for: imageID)
        image = store.entries.first { $0.id == imageID }!
        try check(!ClipboardFilter.cliphoookScreenshot.matches(image) && !image.wasRecorded(on: d4, calendar: calendar),
                  "更正分类/收藏不得生成复制日期")
        _ = try store.addImage(png, type: "public.png", sourceAppName: "Preview")
        try check(store.entries.first { $0.id == imageID }?.screenshotOrigin == .ordinaryImage,
                  "再次复制不能抹去用户对图片分类的更正")
        _ = try store.setScreenshotOrigin(.cliphoook, for: imageID)
        let groupID = try store.groupSelection(memberIDs: [textID, imageID])!
        let group = store.rootEntries.first { $0.id == groupID }!
        try check(group.calendarRecordTimes.isEmpty, "手动成组不应生成复制日期")
        let grouped = [group]
        let groupedInventory = ClipboardFilterInventory(entries: grouped)
        try check(groupedInventory.matching(grouped, filter: .image, query: "alpha", date: d1, calendar: calendar).isEmpty,
                  "分组的类型、关键词、日期必须匹配同一个成员")
        try check(groupedInventory.matching(grouped, filter: .cliphoookScreenshot, query: "Preview",
                  date: d2, calendar: calendar, tab: .favoriteCategory(screenshots.id)).count == 1,
                  "日期、收藏、截图类别和关键词未正确取交集")
        for filter in ClipboardFilter.primary {
            let daily = groupedInventory.dailyCounts(grouped, filter: filter, query: "", calendar: calendar)
            for day in [d1, d2, d3, d4] {
                let list = groupedInventory.matching(grouped, filter: filter, query: "", date: day, calendar: calendar)
                try check(daily[calendar.startOfDay(for: day), default: 0] == list.count,
                          "日历计数与卡片列表不一致：\(filter.label)")
            }
        }
        now = d5
        _ = try store.recordCopy(of: groupID)
        _ = try store.ungroupSelection(groupIDs: [groupID])
        let reloaded = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now }, calendar: calendar)
        try check(reloaded.errorMessage == nil, "日期迁移后重启失败")
        for id in [textID, imageID] {
            try check(reloaded.entries.first { $0.id == id }?.wasRecorded(on: d5, calendar: calendar) == true,
                      "整组复制的日期在取消成组或重启后丢失")
        }
        let loadedImage = reloaded.entries.first { $0.id == imageID }!
        try check(loadedImage.screenshotOrigin == .cliphoook && loadedImage.isFavorite,
                  "重启丢失分类或收藏")
        try reloaded.delete(loadedImage)
        let afterDelete = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now }, calendar: calendar)
        try check(!afterDelete.entries.contains { $0.id == imageID }, "已删除内容不能被日历恢复")
        try check(try sqlInteger(folder.appendingPathComponent("history.sqlite"),
                  "SELECT COUNT(*) FROM history_record_times WHERE entry_id = '\(imageID.uuidString)'") == 0,
                  "删除历史未同时清理日期索引")

        let phoneFolder = root.appendingPathComponent("phone")
        let phoneStore = ClipboardHistoryStore(directory: phoneFolder, defaults: defaults, now: { now })
        _ = try phoneStore.importPhoneScreenshot(png, type: "public.png")
        let phoneID = phoneStore.entries[0].id
        _ = try phoneStore.addImage(png, type: "public.png", sourceAppName: "Preview")
        try check(phoneStore.entries[0].id == phoneID && phoneStore.entries[0].resolvedScreenshotOrigin == .phone,
                  "重新复制 iPhone 截图不得丢失来源类别")

        try migration(root: root.appendingPathComponent("migration"))
        try calendarGeometry(calendar: calendar)
        try thirdPartyScreenshots(root: root.appendingPathComponent("third-party"), defaults: defaults,
                                  png: png, date: d1)
        try textEditing(root: root.appendingPathComponent("text-editing"), defaults: defaults, board: board)
        print("Clipboard calendar smoke passed: migration, deduplication, dates, groups, combined filters, third-party capture, historical backfill, pasteboard and deletion")
        print("Clipboard text editing smoke passed: rollback, reclassification, duplicate handling, groups, persistence and copying")
    }

    @MainActor
    private static func textEditing(root: URL, defaults: UserDefaults, board: NSPasteboard) throws {
        let store = ClipboardHistoryStore(directory: root, defaults: defaults)
        let html = Data("<b>原文</b>".utf8)
        let link = "https://example.com/edited"
        _ = try store.addRichText("原文", rtf: nil, html: html, rtfd: nil, sourceAppName: "Notes")
        let id = store.entries[0].id
        _ = try store.addText("同组成员", sourceAppName: "Notes")
        let otherID = store.entries[0].id
        _ = try store.addText(link, sourceAppName: "Safari")
        let linkID = store.entries[0].id
        let groupID = try store.groupSelection(memberIDs: [id, otherID])!
        try store.setFavorites([id], isFavorite: true)
        let original = store.entries.first { $0.id == id }!
        let group = store.entries.first { $0.id == groupID }!
        let noChange = try store.editText("原文", original: original)
        try check(noChange == nil && store.richTextData(for: original).html == html, "未修改时必须保留富文本")

        let index = root.appendingPathComponent("history.sqlite")
        let content = root.appendingPathComponent("Content")
        let oldFiles = Set(try FileManager.default.contentsOfDirectory(atPath: content.path))
        var handle: OpaquePointer?
        try check(sqlite3_open(index.path, &handle) == SQLITE_OK, "无法打开编辑回归测试夹具")
        defer { sqlite3_close(handle) }
        try check(sqlite3_exec(handle, """
            CREATE TRIGGER reject_group_edit BEFORE UPDATE OF digest ON history_entries
            WHEN NEW.kind = 'group' BEGIN SELECT RAISE(ABORT, 'fixture'); END;
            """, nil, nil, nil) == SQLITE_OK, "无法模拟分组写入失败")
        do {
            _ = try store.editText(link, original: original)
            throw Failure.failed("写入分组失败时编辑仍被提交")
        } catch ClipboardHistoryDatabaseError.operationFailed(_) { }
        try check(Set(try FileManager.default.contentsOfDirectory(atPath: content.path)) == oldFiles &&
                  store.richTextData(for: original).html == html, "失败编辑破坏了原文件或留下了新文件")
        let rolledBack = ClipboardHistoryStore(directory: root, defaults: defaults)
        let restoredOriginal = rolledBack.entries.first { $0.id == id }
        try check(restoredOriginal?.text == original.text && restoredOriginal?.digest == original.digest &&
                  restoredOriginal?.isFavorite == true && store.entries.contains(original),
                  "回滚未保留磁盘及内存中的旧记录")
        try check(sqlite3_exec(handle, "DROP TRIGGER reject_group_edit", nil, nil, nil) == SQLITE_OK,
                  "无法解除模拟错误")

        let boardVersion = board.changeCount
        let editedLink = try store.editText(link, original: original)!
        let updatedGroup = store.rootEntries.first { $0.id == groupID }!
        try check(editedLink.id == id && editedLink.kind == .link && editedLink.webURL?.absoluteString == link &&
                  !editedLink.hasRichText && store.richTextData(for: original).html == nil,
                  "编辑后的链接分类或富文本文件清理有误")
        try check(store.entries.contains { $0.id == linkID && $0.text == link } &&
                  updatedGroup.groupMemberIDs == [id, otherID] && updatedGroup.groupMembers[0] == editedLink &&
                  updatedGroup.digest != group.digest, "相同文本合并了卡片或分组仍指向旧内容")
        try check(editedLink.isFavorite && editedLink.createdAt == original.createdAt &&
                  editedLink.copyCount == original.copyCount && editedLink.sourceAppName == original.sourceAppName &&
                  editedLink.calendarRecordTimes == original.calendarRecordTimes && board.changeCount == boardVersion,
                  "编辑改变了收藏、来源、复制时间或剪贴板")
        do {
            _ = try store.editText("旧草稿", original: original)
            throw Failure.failed("旧草稿覆盖了新修改")
        } catch ClipboardHistoryStoreError.textEditConflict { }
        do {
            _ = try store.editText("", original: editedLink)
            throw Failure.failed("空白正文被保存")
        } catch ClipboardHistoryStoreError.textEditEmpty { }

        let markdown = "# 新标题\n\n**重点**  \n"
        let editedText = try store.editText(markdown, original: editedLink)!
        let reloaded = ClipboardHistoryStore(directory: root, defaults: defaults)
        let restored = reloaded.entries.first { $0.id == id }!
        try check(restored.kind == .text && restored.textClassification == .markdown &&
                  restored.text == markdown && restored.isFavorite, "重启后编辑原文或格式分类丢失")
        let rows = reloaded.rootEntries
        let inventory = ClipboardFilterInventory(entries: rows)
        try check(inventory.matching(rows, filter: .markdown, query: "新标题").map(\.id) == [groupID] &&
                  inventory.matching(rows, filter: .all, query: "原文").isEmpty,
                  "搜索和分组筛选未更新")
        try check(ClipboardPasteboardWriter.write(restored, from: reloaded, to: board) &&
                  board.string(forType: .string) == markdown && board.data(forType: .html) == nil,
                  "复制未取到编辑后的原文")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: content.path))
        try check(files.count == oldFiles.count && files.contains(editedText.textFileName) &&
                  !files.contains(original.textFileName) && !files.contains(editedLink.textFileName),
                  "重复编辑留下了旧正文文件")
    }

    @MainActor
    static func thirdPartyScreenshots(root: URL, defaults: UserDefaults, png: Data, date: Date) throws {
        let producers = [
            ("CleanShot X", "pl.maketheweb.cleanshotx"), ("Snipaste", "com.Snipaste"),
            ("Xnip", "com.zzd.Xnip"), ("XnipHelper", "com.zzd.XnipHelper")
        ]
        let oldStore = ClipboardHistoryStore(directory: root, defaults: defaults, now: { date })
        var legacy: [ClipboardEntry] = []
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for (index, source) in producers.enumerated() {
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            board.clearContents()
            try check(board.writeObjects([item]), "无法创建第三方截图剪贴板")
            let captured = try ClipboardBatchCapture.capture(from: board,
                sourceAppName: source.0, sourceAppBundleID: source.1,
                maximumImageBytes: oldStore.maximumImageBytes, maximumTextBytes: oldStore.maximumTextBytes,
                maximumRichTextBytes: oldStore.maximumRichTextBytes)
            guard case .image(_, _, .screen) = captured.first else {
                throw Failure.failed("未识别截图来源 \(source.0)")
            }
            _ = try oldStore.addImage(png, type: "public.png", sourceAppName: source.0,
                                      sourceAppBundleID: source.1, occurrence: index)
            var entry = oldStore.entries.first { $0.sourceAppBundleID == source.1 }!
            try check(entry.screenshotOrigin == .screen, "保存时未记录第三方截图来源")
            // Recreate a pre-270 row: known source, no stored capture channel.
            entry.screenshotOrigin = nil
            legacy.append(entry)
        }
        _ = try oldStore.addImage(png, type: "public.png", sourceAppName: "Preview",
                                  sourceAppBundleID: "com.apple.Preview", occurrence: 5)
        let ordinary = oldStore.entries.first { $0.sourceAppBundleID == "com.apple.Preview" }!
        _ = try oldStore.addImage(png, type: "public.png", sourceAppName: "CleanShot X",
                                  sourceAppBundleID: "pl.maketheweb.cleanshotx", occurrence: 6,
                                  screenshotOrigin: .ordinaryImage)
        let correctedID = oldStore.entries.first { $0.screenshotOrigin == .ordinaryImage }!.id
        _ = try oldStore.addImage(png, type: "public.png", sourceAppName: "CleanShot X",
                                  sourceAppBundleID: "pl.maketheweb.cleanshotx", occurrence: 6)
        try check(oldStore.entries.first { $0.id == correctedID }?.screenshotOrigin == .ordinaryImage,
                  "自动识别不能覆盖用户的普通图片分类")
        let database = try ClipboardHistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
        for entry in legacy { try database.upsert(entry) }
        try check(try !database.updateScreenshotOrigin(.screen, for: correctedID, onlyIfUnset: true),
                  "历史回填不能覆盖已有的手动更正")
        try check(try !database.updateScreenshotOrigin(.screen, for: UUID(), onlyIfUnset: true),
                  "历史回填不应重建已删除的记录")
        database.close()
        let restored = ClipboardHistoryStore(directory: root, defaults: defaults, now: { date.addingTimeInterval(86400) })
        try check(restored.errorMessage == nil, "历史截图来源回填失败")
        for entry in legacy {
            let updated = restored.entries.first { $0.id == entry.id }!
            try check(updated.screenshotOrigin == .screen && updated.copyCount == entry.copyCount &&
                      updated.createdAt == entry.createdAt && updated.calendarRecordTimes == entry.calendarRecordTimes &&
                      updated.sourceAppBundleID == entry.sourceAppBundleID,
                      "回填来源不能增加复制次数、日期或修改来源应用")
        }
        try check(restored.entries.first { $0.id == ordinary.id }?.resolvedScreenshotOrigin == nil &&
                  restored.entries.first { $0.id == correctedID }?.resolvedScreenshotOrigin == .ordinaryImage,
                  "回填误把普通图片分类为截图")
        let inventory = ClipboardFilterInventory(entries: restored.rootEntries)
        try check(inventory.count(for: .screenScreenshot) == producers.count,
                  "历史第三方截图未进入分类统计")
        let reload = ClipboardHistoryStore(directory: root, defaults: defaults, now: { date })
        try check(ClipboardFilterInventory(entries: reload.rootEntries).count(for: .screenScreenshot) == producers.count,
                  "第三方分类重启后丢失")
        try check(ClipboardScreenshotOrigin.knownSource(name: "CleanShot X", bundleID: nil) == .screen &&
                  ClipboardScreenshotOrigin.knownSource(name: "CleanShot X", bundleID: "com.apple.Preview") == nil,
                  "旧名称兜底必须尊重明确的应用标识")
        let produced = NSPasteboardItem()
        produced.setData(png, forType: .png)
        produced.setString("pl.maketheweb.cleanshotx", forType: ClipboardScreenshotMetadata.producerType)
        try check(ClipboardScreenshotMetadata.origin(in: produced, sourceBundleID: "com.apple.Safari") == .screen,
                  "当前台仍为浏览器时应识别剪贴板的明确截图来源")
        produced.setString(ClipboardScreenshotOrigin.cliphoook.rawValue, forType: ClipboardScreenshotMetadata.pasteboardType)
        try check(ClipboardScreenshotMetadata.origin(in: produced) == .cliphoook,
                  "截图来源检测不应覆盖 ClipHoook 原始分类")
    }

    static func migration(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.sqlite")
        var db: OpaquePointer?
        try check(sqlite3_open(url.path, &db) == SQLITE_OK, "无法创建旧版数据库")
        let id = UUID()
        let oldSQL = """
            CREATE TABLE history_entries (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, digest TEXT NOT NULL UNIQUE,
              first_copied_at REAL, last_copied_at REAL NOT NULL, copy_count INTEGER,
              image_file_name TEXT, image_pasteboard_type TEXT, byte_count INTEGER NOT NULL,
              source_app_name TEXT, source_app_bundle_id TEXT, rtf_file_name TEXT, html_file_name TEXT,
              rtfd_file_name TEXT, file_path TEXT, file_name TEXT, file_type TEXT,
              file_bookmark_name TEXT, file_copy_name TEXT, is_favorite INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE history_group_members (group_id TEXT, member_id TEXT, position INTEGER);
            INSERT INTO history_entries(id, kind, digest, first_copied_at, last_copied_at, copy_count, byte_count)
              VALUES ('\(id.uuidString)', 'text', 'legacy', 1000, 999999, 7, 0);
            PRAGMA user_version = 4;
            """
        let status = sqlite3_exec(db, oldSQL, nil, nil, nil)
        sqlite3_close(db)
        try check(status == SQLITE_OK, "旧版数据库夹具失败")
        let database = try ClipboardHistoryDatabase(url: url)
        var entry = try database.entries(contentDirectory: root)[0]
        try check(entry.calendarRecordTimes.map(\.timeIntervalSince1970) == [1000, 999999],
                  "旧记录只能回填首次/最近日期，不能推测中间五次复制")
        entry.isFavorite = true
        try database.upsert(entry)
        try check(try database.entries(contentDirectory: root)[0].calendarRecordTimes.count == 2,
                  "只修改收藏不能增加日期")
        database.close()
        try check(try sqlInteger(url, "PRAGMA user_version") == 6, "历史升级版本不正确")
    }

    static func calendarGeometry(calendar: Calendar) throws {
        var local = calendar
        local.firstWeekday = 2
        let month = ClipboardCalendarMonth(containing: date("2026-02-14T12:00:00+08:00"), calendar: local)
        let days = month.cells.compactMap { $0 }
        try check(month.cells.count == 42 && days.count == 28 && month.cells.prefix(6).allSatisfy { $0 == nil },
                  "月历星期起点、留白或日期范围错误")
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeDST = date("2026-03-08T00:30:00-08:00")
        let afterDST = date("2026-03-08T23:30:00-07:00")
        var fixture = ClipboardEntry(id: UUID(), createdAt: afterDST, firstCopiedAt: beforeDST, copyCount: 2,
            kind: .text, text: "DST", imageFileName: nil, imagePasteboardType: nil,
            digest: "dst", byteCount: 3, sourceAppName: nil, sourceAppBundleID: nil)
        fixture.recordedAt = [beforeDST, afterDST]
        let inventory = ClipboardFilterInventory(entries: [fixture])
        try check(inventory.dailyCounts([fixture], filter: .all, query: "", calendar: local).count == 1,
                  "夏令时的一天不能按固定 24 小时拆成两天")
        try check(ClipboardCalendarMonth(containing: beforeDST, calendar: local).cells.compactMap { $0 }.count == 31,
                  "夏令时月份缺失或重复日期")
    }

    static func sqlInteger(_ url: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw Failure.failed("无法检查隔离数据库")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.failed("数据库检查语句失败")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.failed("数据库检查无结果") }
        return Int(sqlite3_column_int(statement, 0))
    }

    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }
}
