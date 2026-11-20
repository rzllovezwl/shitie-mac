import Foundation
import SQLite3

@main
struct CardReorderingSmoke {
    enum Failure: Error { case failed(String) }

    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipHoookReorder-\(UUID())")
        let suite = "ClipHoookReorder-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set("forever", forKey: HistoryStoragePolicy.retentionKey)
        defaults.set(0, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ClipboardHistoryStore(directory: root, defaults: defaults, now: { now })
        func add(_ text: String) throws -> UUID {
            now.addTimeInterval(1)
            _ = try store.addText(text, sourceAppName: "排序测试")
            return store.entries[0].id
        }
        func ids(_ scope: ClipboardCardOrderScope = .history) -> [UUID] {
            store.cardOrderEntries(in: scope).map(\.id)
        }
        func reopenedIDs(_ scope: ClipboardCardOrderScope = .history) -> [UUID] {
            ClipboardHistoryStore(directory: root, defaults: defaults, now: { now })
                .cardOrderEntries(in: scope).map(\.id)
        }
        let a = try add("A"), b = try add("B"), c = try add("C"), d = try add("D")
        let original = store.entries
        try check(ids() == [d, c, b, a], "未排序时仍按复制时间倒序")
        try check(try store.reorderCards([a], relativeTo: d, after: false, in: .history), "单卡片应能前移")
        try check(ids() == [a, d, c, b], "插入到卡片之前的位置错误")
        // IDs arrive in an arbitrary selection order; the displayed order wins.
        try check(try store.reorderCards([b, d], relativeTo: c, after: true, in: .history), "多选应整体移动")
        try check(ids() == [a, c, d, b], "多选未保留内部相对顺序")
        try check(reopenedIDs() == ids(), "重启后应恢复手动排序")
        for entry in original {
            let changed = store.entries.first { $0.id == entry.id }!
            try check(changed.createdAt == entry.createdAt && changed.firstCopiedAt == entry.firstCopiedAt &&
                      changed.copyCount == entry.copyCount && changed.recordedAt == entry.recordedAt,
                      "排序不得改变复制时间、次数或日历记录")
        }
        try check(!(try store.reorderCards([d], relativeTo: c, after: true, in: .history)), "相同位置不应写入")
        try check(!(try store.reorderCards([a], relativeTo: a, after: false, in: .history)) &&
                  !(try store.reorderCards([UUID()], relativeTo: a, after: false, in: .history)),
                  "无效或自身落点应拒绝")
        // A filter may expose only A and B. Moving B before A preserves hidden C/D.
        try check(try store.reorderCards([b], relativeTo: a, after: false, in: .history), "筛选中应能换位")
        try check(ids() == [b, a, c, d], "筛选中换位不应丢失未显示卡片的相对顺序")
        now.addTimeInterval(1)
        _ = try store.recordCopy(of: c)
        try check(ids() == [c, b, a, d] && reopenedIDs() == ids(), "重新复制的历史内容应回到最前面")
        let e = try add("E")
        try check(ids() == [e, c, b, a, d], "新内容应排在手动历史前面")

        let work = try store.saveFavoriteCategory(name: "工作", tint: .blue, icon: .clipboard, editing: nil)
        let personal = try store.saveFavoriteCategory(name: "个人", tint: .teal, icon: .account, editing: nil)
        try store.moveFavorites([a, c, d], to: work.id)
        try store.moveFavorites([b, e], to: personal.id)
        let history = ids()
        try check(try store.reorderCards([a], relativeTo: c, after: false, in: .favorite(work.id)), "收藏应能独立排序")
        try check(ids(.favorite(work.id)) == [a, c, d] && ids() == history, "收藏排序不应改变历史顺序")
        try check(try store.reorderCards([b], relativeTo: e, after: false, in: .favorite(personal.id)), "另一收藏应能排序")
        try check(ids(.favorite(personal.id)) == [b, e] && ids(.favorite(work.id)) == [a, c, d],
                  "收藏分类排序不应互相影响")
        now.addTimeInterval(1)
        _ = try store.recordCopy(of: d)
        try check(ids(.favorite(work.id)) == [a, c, d] && reopenedIDs(.favorite(work.id)) == [a, c, d],
                  "重新复制不应改变收藏的手动顺序")
        let f = try add("F")
        try store.moveFavorites([f], to: work.id)
        try check(ids(.favorite(work.id)) == [f, a, c, d], "新收藏应排在分类最前面")
        try check(try store.reorderCards([f], relativeTo: d, after: true, in: .favorite(work.id)), "新收藏应可移到末尾")
        try store.moveFavorites([d], to: personal.id)
        try check(ids(.favorite(personal.id)).first == d && reopenedIDs(.favorite(work.id)) == [a, c, f],
                  "移动分类应清除旧分类排序，不应沿用离开的排名")

        _ = try store.setShelfPinned([a, c, f], pinned: true)
        let pins = ids(.pins)
        try check(!store.canReorderCards([a], in: .history), "钉住卡片不能隐式移回普通区")
        try check(try store.reorderCards([pins[2]], relativeTo: pins[0], after: false, in: .pins), "钉住区应可排序")
        try check(ids(.pins) == [pins[2], pins[0], pins[1]] && reopenedIDs(.pins) == ids(.pins),
                  "钉住区排序应独立持久化")
        _ = try store.setShelfPinned([a, c, f], pinned: false)
        try check(ids(.favorite(work.id)) == [a, c, f], "取消钉住应恢复该分类的原有手动顺序")

        let g1 = try add("组一"), g2 = try add("组二"), g3 = try add("组三")
        let groupID = try store.groupSelection(memberIDs: [g1, g2, g3])!
        _ = try store.setShelfPinned([g2], pinned: true)
        let scope = ClipboardCardOrderScope.group(groupID)
        try check(ids(scope) == [g1, g3], "钉住成员不应参与组内拖动")
        try check(try store.reorderCards([g3], relativeTo: g1, after: false, in: scope), "组内应能换位")
        let group = store.entries.first { $0.id == groupID }!
        try check(group.groupMemberIDs == [g3, g2, g1] && reopenedIDs(scope) == [g3, g1],
                  "组内换位应保留钉住成员槽位并持久化")
        try check(!store.canReorderCards([g3], in: .history) && !store.canReorderCards([a], in: scope),
                  "组内换位不应改变分组归属")

        // A failure after deleting the old ranks must roll back both disk and memory.
        let sqlURL = root.appendingPathComponent("history.sqlite")
        let db = try ClipboardHistoryDatabase(url: sqlURL)
        let diskOrder = reopenedIDs()
        let entriesBeforeFailure = store.entries
        let ordered = store.cardOrderEntries(in: .history)
        do {
            try db.transaction { try db.saveCardOrder([ordered[0], ordered[0]], scope: "history") }
            throw Failure.failed("重复排序记录应触发事务回滚")
        } catch is ClipboardHistoryDatabaseError {}
        try check(reopenedIDs() == diskOrder, "失败后旧排序必须仍在")
        try execute("""
            CREATE TRIGGER reject_card_order BEFORE INSERT ON history_card_order
            BEGIN SELECT RAISE(ABORT, 'test rollback'); END;
            """, at: sqlURL)
        do {
            _ = try store.reorderCards([diskOrder.last!], relativeTo: diskOrder.first!, after: false, in: .history)
            throw Failure.failed("存储失败不应报告排序成功")
        } catch is ClipboardHistoryDatabaseError {}
        try check(store.entries == entriesBeforeFailure && reopenedIDs() == diskOrder,
                  "排序写入失败不得修改内存或持久记录")
        try execute("DROP TRIGGER reject_card_order", at: sqlURL)
        try store.deleteFavoriteCategory(work.id)
        try check(store.entries.allSatisfy { $0.cardOrders["favorite:\(work.id.uuidString)"] == nil } &&
                  ClipboardHistoryStore(directory: root, defaults: defaults).entries.allSatisfy {
                      $0.cardOrders["favorite:\(work.id.uuidString)"] == nil
                  }, "删除分类应清理对应排序")
        let deleted = store.entries.first { $0.id == e }!
        try store.delete(deleted)
        try check(!reopenedIDs(.favorite(personal.id)).contains(e), "删除卡片后排序记录不应留下失效引用")

        // Retention works from actual copy dates, even when oldest is displayed first.
        let retentionFolder = root.appendingPathComponent("retention")
        let retention = ClipboardHistoryStore(directory: retentionFolder, defaults: defaults, now: { now })
        _ = try retention.addText("旧内容", sourceAppName: nil)
        let oldID = retention.entries[0].id
        now.addTimeInterval(3 * 86_400)
        _ = try retention.addText("新内容", sourceAppName: nil)
        let newID = retention.entries[0].id
        _ = try retention.reorderCards([oldID], relativeTo: newID, after: false, in: .history)
        defaults.set("1d", forKey: HistoryStoragePolicy.retentionKey)
        _ = try retention.applyStoragePolicy()
        try check(retention.entries.map(\.id) == [newID], "手动排序不应改变到期清理依据")
        print("Card reordering smoke passed: history, filters, multi-selection, favorites, pins, groups, restart, rollback and retention")
    }

    static func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure.failed("测试数据库未打开") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.failed("测试 SQL 执行失败") }
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.failed(message) }
    }
}
