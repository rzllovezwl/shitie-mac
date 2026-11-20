import Foundation
import SQLite3

@main
struct ClipboardFavoritesSmoke {
    enum Failure: Error { case failed(String) }

    @MainActor
    static func main() throws {
        let icons = ClipboardFavoriteCategory.Icon.allCases
        let emojis = icons.map { $0.presentation.emoji }
        try check(icons.count == 40 && Set(emojis).count == 40 && emojis.allSatisfy { emoji in
            emoji.count == 1 && emoji.unicodeScalars.contains {
                $0.properties.isEmojiPresentation || $0.value == 0xFE0F
            }
        }, "收藏分类应提供 40 个不同的彩色 Emoji")
        try check(icons.prefix(5).map { $0.presentation.label } == ["密码", "账号", "邮箱", "手机号", "地址"],
                  "常用信息图标应排在前面")
        try check(ClipboardFavoriteCategory.Icon(rawValue: "link-2") == .link, "旧版的链接图标应继续可读")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookFavorites-\(UUID().uuidString)")
        let suite = "ClipHoookFavorites-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("forever", forKey: HistoryStoragePolicy.retentionKey)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = root.appendingPathComponent("history")
        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        try check(store.favoriteCategories.isEmpty, "新安装不应创建默认收藏分类")
        _ = try store.addText("长期保留的文字", sourceAppName: "笔记")
        let original = store.entries[0]
        try store.setFavorites([original.id], isFavorite: true)
        try check(store.entries[0].createdAt == original.createdAt &&
                  store.entries[0].copyCount == original.copyCount && store.entries[0].favoriteCategoryID == nil,
                  "收藏不应改动复制时间或次数")
        let work = try store.saveFavoriteCategory(name: "  工作  ", tint: .teal, icon: .clipboard, editing: nil)
        let samples = try store.saveFavoriteCategory(name: "素材", tint: .blue, icon: .image, editing: nil)
        try check(work.name == "工作", "分类应去掉首尾空白")
        do {
            _ = try store.saveFavoriteCategory(name: "历史", tint: .red, icon: .star, editing: nil)
            throw Failure.failed("自定义分类不应使用历史标签的名称")
        } catch ClipboardHistoryStoreError.favoriteCategoryNameTaken {}
        do {
            _ = try store.saveFavoriteCategory(name: "工作", tint: .green, icon: .file, editing: samples.id)
            throw Failure.failed("不能把分类改成已有名称")
        } catch ClipboardHistoryStoreError.favoriteCategoryNameTaken {}
        let edited = try store.saveFavoriteCategory(name: "项目", tint: .purple, icon: .password, editing: work.id)
        try store.moveFavorites([original.id], to: work.id)
        now.addTimeInterval(1)
        _ = try store.addText("普通文字", sourceAppName: "笔记")
        _ = try store.addText("长期保留的文字", sourceAppName: "笔记")
        try check(store.entries.first(where: { $0.id == original.id })?.favoriteCategoryID == work.id,
                  "重复复制丢失了收藏分类")
        let reopened = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        try check(reopened.favoriteCategories == [edited, samples] &&
                  reopened.entries.first(where: { $0.id == original.id })?.favoriteCategoryID == work.id,
                  "重启未恢复分类名称、颜色、图标、顺序和归属")

        now.addTimeInterval(3 * 86_400)
        defaults.set("1d", forKey: HistoryStoragePolicy.retentionKey)
        _ = try store.applyStoragePolicy()
        try check(store.entries.map(\.id) == [original.id], "到期清理未跳过收藏或阻塞了普通记录清理")
        let textFile = folder.appendingPathComponent("Content/\(original.id.uuidString).txt")
        try check(FileManager.default.fileExists(atPath: textFile.path), "收藏内容文件被自动删除")

        _ = try store.addText(String(repeating: "x", count: 2 * 1_024 * 1_024), sourceAppName: "笔记")
        let largeID = store.entries[0].id
        try store.setFavorites([largeID], isFavorite: true)
        _ = try store.addText("可自动清理", sourceAppName: "笔记")
        defaults.set(1, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        _ = try store.applyStoragePolicy()
        try check(store.entries.count == 2 && store.entries.allSatisfy(\.isFavorite)
                  && store.activeStorageBytes > 1_024 * 1_024,
                  "收藏超过空间上限时应保留，并继续清理普通记录")
        try store.setFavorites([largeID], isFavorite: false)
        _ = try store.applyStoragePolicy()
        try check(!store.entries.contains(where: { $0.id == largeID }), "取消收藏后应恢复普通清理规则")

        defaults.set(0, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        _ = try store.addText("组内一", sourceAppName: "笔记")
        let firstID = store.entries[0].id
        _ = try store.addText("组内二", sourceAppName: "笔记")
        let secondID = store.entries[0].id
        let groupID = try store.groupSelection(memberIDs: [firstID, secondID])!
        try store.moveFavorites([firstID], to: samples.id)
        try store.moveFavorites([groupID], to: work.id)
        now.addTimeInterval(3 * 86_400)
        _ = try store.applyStoragePolicy()
        try check([groupID, firstID, secondID].allSatisfy { id in store.entries.contains { $0.id == id } },
                  "收藏分组没有保护全部成员")
        _ = try store.ungroupSelection(groupIDs: [groupID])
        try check(store.entries.first(where: { $0.id == firstID })?.favoriteCategoryID == samples.id &&
                  store.entries.first(where: { $0.id == secondID })?.favoriteCategoryID == work.id,
                  "取消成组时应继承整组收藏分类并保留已独立收藏的成员")
        try store.deleteFavoriteCategory(work.id)
        let afterDeletion = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        try check(afterDeletion.favoriteCategories == [samples] &&
                  [original.id, secondID].allSatisfy { id in
                      afterDeletion.entries.contains { $0.id == id && $0.isFavorite && $0.favoriteCategoryID == nil }
                  }, "删除分类后卡片应保留在历史中，并继续有星标")
        try store.setFavorites([firstID], isFavorite: false)
        try store.setFavorites([firstID], isFavorite: true)
        try check(store.entries.first(where: { $0.id == firstID })?.favoriteCategoryID == nil,
                  "旧版重新加星后不应恢复原来的分类")
        try store.delete(store.entries.first(where: { $0.id == firstID })!)
        try check(!store.entries.contains { $0.id == firstID }, "手动删除收藏失效")

        defaults.set("forever", forKey: HistoryStoragePolicy.retentionKey)
        _ = try store.addText("拖入新分类的卡片", sourceAppName: "笔记")
        let draggedID = store.entries[0].id
        do {
            _ = try store.saveFavoriteCategory(name: "临时", tint: .teal, icon: .email, editing: nil,
                                               collecting: [draggedID, UUID()])
            throw Failure.failed("卡片已失效时应阻止创建及归类")
        } catch ClipboardHistoryStoreError.historyEntryMissing {}
        try check(store.favoriteCategories == [samples] && !store.entries[0].isFavorite,
                  "创建失败时不应留下分类或部分收藏")
        let ids: Set<UUID> = [draggedID, original.id]
        let created = try store.saveFavoriteCategory(name: "收藏", tint: .green, icon: .address, editing: nil,
                                                     collecting: ids)
        let afterDrop = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        try check(afterDrop.favoriteCategories == [samples, created] &&
                  Set(afterDrop.entries.filter { $0.isFavorite && $0.favoriteCategoryID == created.id }.map(\.id)) == ids,
                  "新建分类并收藏应同时保存普通卡片和旧星标卡片")

        let migrationFolder = root.appendingPathComponent("migration")
        do {
            let fixture = ClipboardHistoryStore(directory: migrationFolder, defaults: defaults)
            _ = try fixture.addText("版本三旧数据", sourceAppName: "旧应用")
        }
        var db: OpaquePointer?
        try check(sqlite3_open(migrationFolder.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK,
                  "无法创建版本三夹具")
        let migrationResult = sqlite3_exec(db, """
            DROP TRIGGER history_remove_unstarred_membership;
            DROP TABLE history_shelf_pins;
            DROP TABLE history_favorite_members;
            DROP TABLE history_favorite_categories;
            DROP TABLE history_record_times;
            ALTER TABLE history_entries DROP COLUMN text_revision;
            ALTER TABLE history_entries DROP COLUMN screenshot_origin;
            ALTER TABLE history_entries DROP COLUMN is_favorite;
            PRAGMA user_version = 3;
            """, nil, nil, nil)
        sqlite3_close(db)
        try check(migrationResult == SQLITE_OK, "无法模拟版本三数据库")
        let migrated = ClipboardHistoryStore(directory: migrationFolder, defaults: defaults)
        try check(migrated.errorMessage == nil && migrated.entries.first?.text == "版本三旧数据"
                  && migrated.entries.first?.isFavorite == false &&
                  migrated.entries.first?.shelfPinOrder == nil, "新增分类和钉住状态应保留旧历史")
        try migrated.setFavorites([migrated.entries[0].id], isFavorite: true)
        let migratedAgain = ClipboardHistoryStore(directory: migrationFolder, defaults: defaults)
        try check(migratedAgain.entries.first?.isFavorite == true, "迁移后收藏无法保存")
        print("Clipboard favorites smoke test passed: category editing, assignment, persistence, migration, retention, storage limits and groups")
        try checkShelfPins(in: root.appendingPathComponent("shelf-pins"), defaults: defaults)
    }

    @MainActor
    private static func checkShelfPins(in folder: URL, defaults: UserDefaults) throws {
        defaults.set("forever", forKey: HistoryStoragePolicy.retentionKey)
        defaults.set(0, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        _ = try store.addText("组内钉住", sourceAppName: "笔记")
        let memberID = store.entries[0].id
        now.addTimeInterval(1)
        _ = try store.addText("普通成员", sourceAppName: "笔记")
        let otherMemberID = store.entries[0].id
        let groupID = try store.groupSelection(memberIDs: [memberID, otherMemberID])!
        try check(store.rootEntries.map(\.id) == [groupID], "组内记录应先折叠在组中")

        try store.setShelfPinned([memberID], pinned: true)
        let memberOrder = store.entries.first { $0.id == memberID }!.shelfPinOrder
        try check(store.rootEntries.contains { $0.id == memberID } &&
                  store.rootEntries.first { $0.id == groupID }?.groupMemberIDs == [memberID, otherMemberID],
                  "组内卡片应独立钉住并保留组内归属")
        try store.setShelfPinned([memberID], pinned: false)
        try check(store.rootEntries.map(\.id) == [groupID], "取消组内卡片钉住后应归回分组")
        try store.setShelfPinned([memberID], pinned: true)

        now.addTimeInterval(1)
        _ = try store.addText(String(repeating: "p", count: 2 * 1_024 * 1_024), sourceAppName: "笔记")
        let largeID = store.entries[0].id
        try store.setShelfPinned([groupID, largeID, groupID], pinned: true)
        try store.setFavorites([memberID], isFavorite: true)
        try store.setFavorites([memberID], isFavorite: false)
        _ = try store.recordCopy(of: memberID)
        let reopened = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        let order = reopened.entries.compactMap { entry in entry.shelfPinOrder.map { ($0, entry.id) } }
            .sorted { $0.0 > $1.0 }.map { $0.1 }
        try check(order == [groupID, largeID, memberID] && !reopened.entries.contains(where: \.isFavorite) &&
                  reopened.entries.first { $0.id == memberID }?.shelfPinOrder == memberOrder,
                  "复制、收藏和重启应保留钉住状态及批量顺序")

        _ = try store.addText("应按容量清理", sourceAppName: "笔记")
        defaults.set(1, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        _ = try store.applyStoragePolicy()
        try check(Set(store.entries.map(\.id)) == [memberID, otherMemberID, groupID, largeID] &&
                  store.activeStorageBytes > 1_024 * 1_024, "容量清理应跳过钉住卡片和已钉分组的成员")

        now.addTimeInterval(3 * 86_400)
        defaults.set("1d", forKey: HistoryStoragePolicy.retentionKey)
        _ = try store.applyStoragePolicy()
        try check(store.entries.count == 4, "到期清理应跳过钉住卡片和已钉分组的成员")
        try store.setShelfPinned([groupID, memberID], pinned: false)
        _ = try store.applyStoragePolicy()
        try check(store.entries.map(\.id) == [largeID], "取消钉住后应恢复清理规则")
        try store.delete(store.entries[0])
        let empty = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        try check(empty.entries.isEmpty && empty.errorMessage == nil, "手动删除钉住卡片后历史应能正常打开")
        print("Shelf pin smoke test passed: grouping, batch order, persistence, copying, expiry and size limits")
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.failed(message) }
    }
}
