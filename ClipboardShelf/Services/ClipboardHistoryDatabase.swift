import Foundation
import SQLite3

enum ClipboardHistoryDatabaseError: LocalizedError {
    case openFailed
    case operationFailed(Int32)
    case unsupportedVersion(Int32)
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .openFailed: "无法打开历史数据库。"
        case .operationFailed(let code): "历史数据库操作失败（SQLite \(code)）。"
        case .unsupportedVersion: "历史数据库来自较新的应用版本，当前版本不能修改。"
        case .invalidRecord: "历史数据库包含无效记录。"
        }
    }
}

/// Keeps metadata in SQLite while text and image payloads remain ordinary
/// files. SQL never contains clipboard contents; values are always bound.
final class ClipboardHistoryDatabase {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw ClipboardHistoryDatabaseError.openFailed
        }

        do {
            try execute("PRAGMA busy_timeout = 2000")
            try execute("PRAGMA secure_delete = ON")
            try execute("PRAGMA foreign_keys = ON")
            let version = try userVersion()
            guard version <= 6 else {
                throw ClipboardHistoryDatabaseError.unsupportedVersion(version)
            }
            if version == 0 {
                try execute("PRAGMA auto_vacuum = FULL")
                try execute("""
                    CREATE TABLE IF NOT EXISTS history_entries (
                        id TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        digest TEXT NOT NULL UNIQUE,
                        first_copied_at REAL,
                        last_copied_at REAL NOT NULL,
                        copy_count INTEGER,
                        image_file_name TEXT,
                        image_pasteboard_type TEXT,
                        byte_count INTEGER NOT NULL,
                        source_app_name TEXT,
                        source_app_bundle_id TEXT,
                        rtf_file_name TEXT,
                        html_file_name TEXT,
                        rtfd_file_name TEXT,
                        file_path TEXT,
                        file_name TEXT,
                        file_type TEXT,
                        file_bookmark_name TEXT,
                        file_copy_name TEXT
                    )
                    """)
                try execute("CREATE INDEX IF NOT EXISTS history_by_recent_copy ON history_entries(last_copied_at DESC)")
                try execute("CREATE INDEX IF NOT EXISTS history_by_source ON history_entries(source_app_bundle_id)")
                try execute("CREATE INDEX IF NOT EXISTS history_by_kind ON history_entries(kind)")
                try execute("PRAGMA user_version = 2")
            } else if version == 1 {
                try transaction {
                    try execute("ALTER TABLE history_entries ADD COLUMN rtf_file_name TEXT")
                    try execute("ALTER TABLE history_entries ADD COLUMN html_file_name TEXT")
                    try execute("ALTER TABLE history_entries ADD COLUMN rtfd_file_name TEXT")
                    try execute("ALTER TABLE history_entries ADD COLUMN file_path TEXT")
                    try execute("ALTER TABLE history_entries ADD COLUMN file_name TEXT")
                    try execute("ALTER TABLE history_entries ADD COLUMN file_type TEXT")
                    try execute("ALTER TABLE history_entries ADD COLUMN file_bookmark_name TEXT")
                    try execute("ALTER TABLE history_entries ADD COLUMN file_copy_name TEXT")
                    try execute("PRAGMA user_version = 2")
                }
            }
            if version <= 2 {
                try transaction {
                    try execute("""
                        CREATE TABLE history_group_members (
                            group_id TEXT NOT NULL REFERENCES history_entries(id) ON DELETE CASCADE,
                            member_id TEXT NOT NULL REFERENCES history_entries(id) ON DELETE CASCADE,
                            position INTEGER NOT NULL,
                            PRIMARY KEY (group_id, position)
                        )
                        """)
                    try execute("CREATE INDEX group_members_by_member ON history_group_members(member_id)")
                    try execute("PRAGMA user_version = 3")
                }
            }
            if version <= 3 {
                try transaction {
                    try execute("ALTER TABLE history_entries ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0")
                    try execute("PRAGMA user_version = 4")
                }
            }
            if version <= 4 {
                try transaction {
                    try execute("ALTER TABLE history_entries ADD COLUMN screenshot_origin TEXT")
                    try execute("""
                        CREATE TABLE history_record_times (
                            entry_id TEXT NOT NULL REFERENCES history_entries(id) ON DELETE CASCADE,
                            recorded_at REAL NOT NULL,
                            PRIMARY KEY (entry_id, recorded_at)
                        )
                        """)
                    try execute("CREATE INDEX history_records_by_time ON history_record_times(recorded_at)")
                    // Do not invent intermediate copies or turn a grouping
                    // operation into a collection event for the calendar.
                    try execute("""
                        INSERT OR IGNORE INTO history_record_times
                        SELECT id, first_copied_at FROM history_entries
                        WHERE kind != 'group' AND first_copied_at IS NOT NULL
                        """)
                    try execute("""
                        INSERT OR IGNORE INTO history_record_times
                        SELECT id, last_copied_at FROM history_entries WHERE kind != 'group'
                        """)
                    try execute("PRAGMA user_version = 5")
                }
            }
            if version <= 5 {
                try transaction {
                    try execute("ALTER TABLE history_entries ADD COLUMN text_revision TEXT")
                    try execute("PRAGMA user_version = 6")
                }
            }
            // Optional tables keep the v6 history readable by earlier builds.
            // Older stars without a category remain starred in History.
            try transaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS history_recording_metadata (
                        entry_id TEXT PRIMARY KEY NOT NULL REFERENCES history_entries(id) ON DELETE CASCADE,
                        payload TEXT NOT NULL
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS history_card_order (
                        scope TEXT NOT NULL,
                        entry_id TEXT NOT NULL REFERENCES history_entries(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL,
                        copied_at REAL NOT NULL,
                        PRIMARY KEY (scope, entry_id)
                    )
                    """)
                try execute("CREATE INDEX IF NOT EXISTS history_card_order_entry ON history_card_order(entry_id)")
                try execute("""
                    CREATE TABLE IF NOT EXISTS history_favorite_categories (
                        position INTEGER PRIMARY KEY,
                        id TEXT NOT NULL UNIQUE,
                        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
                        tint TEXT NOT NULL,
                        icon TEXT NOT NULL
                    )
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS history_favorite_members (
                        entry_id TEXT PRIMARY KEY NOT NULL REFERENCES history_entries(id) ON DELETE CASCADE,
                        category_id TEXT NOT NULL REFERENCES history_favorite_categories(id) ON DELETE CASCADE
                    )
                    """)
                try execute("""
                    CREATE INDEX IF NOT EXISTS history_favorite_members_category
                    ON history_favorite_members(category_id)
                    """)
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS history_remove_unstarred_membership
                    AFTER UPDATE OF is_favorite ON history_entries WHEN NEW.is_favorite = 0
                    BEGIN
                        DELETE FROM history_favorite_members WHERE entry_id = NEW.id;
                    END
                    """)
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS history_remove_moved_favorite_order
                    AFTER UPDATE OF category_id ON history_favorite_members
                    WHEN NEW.category_id != OLD.category_id
                    BEGIN
                        DELETE FROM history_card_order
                        WHERE entry_id = OLD.entry_id AND scope LIKE 'favorite:%';
                    END
                    """)
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS history_remove_unlinked_favorite_order
                    AFTER DELETE ON history_favorite_members
                    BEGIN
                        DELETE FROM history_card_order
                        WHERE entry_id = OLD.entry_id AND scope LIKE 'favorite:%';
                    END
                    """)
                try execute("""
                    CREATE TABLE IF NOT EXISTS history_shelf_pins (
                        entry_id TEXT PRIMARY KEY NOT NULL REFERENCES history_entries(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL UNIQUE
                    )
                    """)
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func withSavepoint(_ work: () throws -> Void) throws {
        try execute("SAVEPOINT history_change")
        do {
            try work()
            try execute("RELEASE history_change")
        } catch {
            try? execute("ROLLBACK TO history_change")
            try? execute("RELEASE history_change")
            throw error
        }
    }

    func entries(contentDirectory: URL) throws -> [ClipboardEntry] {
        let statement = try prepare("""
            SELECT id, kind, digest, first_copied_at, last_copied_at, copy_count,
                   image_file_name, image_pasteboard_type, byte_count,
                   source_app_name, source_app_bundle_id,
                   rtf_file_name, html_file_name, rtfd_file_name,
                   file_path, file_name, file_type, file_bookmark_name, file_copy_name,
                   is_favorite, screenshot_origin, text_revision, category_id, history_shelf_pins.position
            FROM history_entries
            LEFT JOIN history_favorite_members ON history_favorite_members.entry_id = history_entries.id
            LEFT JOIN history_shelf_pins ON history_shelf_pins.entry_id = history_entries.id
            ORDER BY last_copied_at DESC
            """)
        defer { sqlite3_finalize(statement) }
        var result: [ClipboardEntry] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            guard let idString = string(statement, column: 0),
                  let id = UUID(uuidString: idString),
                  let kindString = string(statement, column: 1),
                  let kind = ClipboardEntry.Kind(rawValue: kindString),
                  let digest = string(statement, column: 2) else {
                throw ClipboardHistoryDatabaseError.invalidRecord
            }
            let firstCopiedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let lastCopiedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let copyCount = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, 5))
            var entry = ClipboardEntry(
                id: id,
                createdAt: lastCopiedAt,
                firstCopiedAt: firstCopiedAt,
                copyCount: copyCount,
                kind: kind,
                text: nil,
                imageFileName: string(statement, column: 6),
                imagePasteboardType: string(statement, column: 7),
                digest: digest,
                byteCount: Int(sqlite3_column_int64(statement, 8)),
                sourceAppName: string(statement, column: 9),
                sourceAppBundleID: string(statement, column: 10)
            )
            entry.rtfFileName = string(statement, column: 11)
            entry.htmlFileName = string(statement, column: 12)
            entry.rtfdFileName = string(statement, column: 13)
            entry.filePath = string(statement, column: 14)
            entry.fileName = string(statement, column: 15)
            entry.fileType = string(statement, column: 16)
            entry.fileBookmarkName = string(statement, column: 17)
            entry.fileCopyName = string(statement, column: 18)
            entry.isFavorite = sqlite3_column_int(statement, 19) != 0
            if entry.isFavorite {
                entry.favoriteCategoryID = string(statement, column: 22).flatMap(UUID.init(uuidString:))
            }
            if sqlite3_column_type(statement, 23) != SQLITE_NULL {
                entry.shelfPinOrder = sqlite3_column_int64(statement, 23)
            }
            entry.screenshotOrigin = string(statement, column: 20).flatMap(ClipboardScreenshotOrigin.init)
            if let revision = string(statement, column: 21) {
                guard let id = UUID(uuidString: revision) else {
                    throw ClipboardHistoryDatabaseError.invalidRecord
                }
                entry.textRevision = id
            }
            if kind.isTextual {
                entry.text = try? String(contentsOf: contentDirectory.appendingPathComponent(entry.textFileName),
                                         encoding: .utf8)
            }
            result.append(entry)
        }
        let recordings = try prepare("SELECT entry_id, payload FROM history_recording_metadata")
        defer { sqlite3_finalize(recordings) }
        var metadata: [UUID: ClipboardRecordingMetadata] = [:]
        while true {
            let step = sqlite3_step(recordings)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure() }
            if let id = string(recordings, column: 0).flatMap(UUID.init(uuidString:)),
               let data = string(recordings, column: 1)?.data(using: .utf8),
               let value = try? JSONDecoder().decode(ClipboardRecordingMetadata.self, from: data) {
                metadata[id] = value
            }
        }
        for index in result.indices { result[index].screenRecording = metadata[result[index].id] }
        let records = try prepare("SELECT entry_id, recorded_at FROM history_record_times ORDER BY recorded_at")
        defer { sqlite3_finalize(records) }
        var times: [UUID: [Date]] = [:]
        while true {
            let step = sqlite3_step(records)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let value = string(records, column: 0),
                  let id = UUID(uuidString: value) else { throw failure() }
            times[id, default: []].append(Date(timeIntervalSince1970: sqlite3_column_double(records, 1)))
        }
        for index in result.indices { result[index].recordedAt = times[result[index].id] ?? [] }
        let members = try prepare("SELECT group_id, member_id FROM history_group_members ORDER BY group_id, position")
        defer { sqlite3_finalize(members) }
        var positions: [UUID: [UUID]] = [:]
        while true {
            let step = sqlite3_step(members)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  let groupString = string(members, column: 0),
                  let memberString = string(members, column: 1),
                  let groupID = UUID(uuidString: groupString),
                  let memberID = UUID(uuidString: memberString) else {
                throw ClipboardHistoryDatabaseError.invalidRecord
            }
            positions[groupID, default: []].append(memberID)
        }
        for index in result.indices where result[index].kind == .group {
            result[index].groupMemberIDs = positions[result[index].id] ?? []
        }
        let orders = try prepare("SELECT scope, entry_id, position, copied_at FROM history_card_order")
        defer { sqlite3_finalize(orders) }
        var byID: [UUID: [String: ClipboardCardOrder]] = [:]
        while true {
            let step = sqlite3_step(orders)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let scope = string(orders, column: 0),
                  let rawID = string(orders, column: 1), let id = UUID(uuidString: rawID) else {
                throw ClipboardHistoryDatabaseError.invalidRecord
            }
            byID[id, default: [:]][scope] = ClipboardCardOrder(
                position: sqlite3_column_int64(orders, 2),
                copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(orders, 3)))
        }
        for index in result.indices { result[index].cardOrders = byID[result[index].id] ?? [:] }
        return result
    }

    @discardableResult
    func updateScreenshotOrigin(_ origin: ClipboardScreenshotOrigin, for id: UUID,
                                onlyIfUnset: Bool = false) throws -> Bool {
        // A classification repair must never rewrite copy metadata from a
        // stale snapshot, or replace a correction made by another process.
        let statement = try prepare("UPDATE history_entries SET screenshot_origin = ? WHERE id = ?" +
                                    (onlyIfUnset ? " AND screenshot_origin IS NULL" : ""))
        defer { sqlite3_finalize(statement) }
        try bind(origin.rawValue, to: 1, in: statement)
        try bind(id.uuidString, to: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE, let handle else { throw failure() }
        return sqlite3_changes(handle) > 0
    }

    func upsert(_ entry: ClipboardEntry) throws {
        // Metadata, membership and collection times must commit together,
        // including callers that are not already in a batch transaction.
        try execute("SAVEPOINT history_group_upsert")
        do {
            try upsertRecordAndMembers(entry)
            try execute("RELEASE history_group_upsert")
        } catch {
            try? execute("ROLLBACK TO history_group_upsert")
            try? execute("RELEASE history_group_upsert")
            throw error
        }
    }

    private func upsertRecordAndMembers(_ entry: ClipboardEntry) throws {
        let statement = try prepare("""
            INSERT INTO history_entries (
                id, kind, digest, first_copied_at, last_copied_at, copy_count,
                image_file_name, image_pasteboard_type, byte_count,
                source_app_name, source_app_bundle_id,
                rtf_file_name, html_file_name, rtfd_file_name,
                file_path, file_name, file_type, file_bookmark_name, file_copy_name,
                is_favorite, screenshot_origin, text_revision
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                digest = excluded.digest,
                first_copied_at = excluded.first_copied_at,
                last_copied_at = excluded.last_copied_at,
                copy_count = excluded.copy_count,
                image_file_name = excluded.image_file_name,
                image_pasteboard_type = excluded.image_pasteboard_type,
                byte_count = excluded.byte_count,
                source_app_name = excluded.source_app_name,
                source_app_bundle_id = excluded.source_app_bundle_id,
                rtf_file_name = excluded.rtf_file_name,
                html_file_name = excluded.html_file_name,
                rtfd_file_name = excluded.rtfd_file_name,
                file_path = excluded.file_path,
                file_name = excluded.file_name,
                file_type = excluded.file_type,
                file_bookmark_name = excluded.file_bookmark_name,
                file_copy_name = excluded.file_copy_name,
                is_favorite = excluded.is_favorite,
                screenshot_origin = excluded.screenshot_origin,
                text_revision = excluded.text_revision
            """)
        defer { sqlite3_finalize(statement) }
        try bind(entry.id.uuidString, to: 1, in: statement)
        try bind(entry.kind.rawValue, to: 2, in: statement)
        try bind(entry.digest, to: 3, in: statement)
        try bind(entry.firstCopiedAt?.timeIntervalSince1970, to: 4, in: statement)
        try bind(entry.createdAt.timeIntervalSince1970, to: 5, in: statement)
        try bind(entry.copyCount.map(Int64.init), to: 6, in: statement)
        try bind(entry.imageFileName, to: 7, in: statement)
        try bind(entry.imagePasteboardType, to: 8, in: statement)
        try bind(Int64(entry.byteCount), to: 9, in: statement)
        try bind(entry.sourceAppName, to: 10, in: statement)
        try bind(entry.sourceAppBundleID, to: 11, in: statement)
        try bind(entry.rtfFileName, to: 12, in: statement)
        try bind(entry.htmlFileName, to: 13, in: statement)
        try bind(entry.rtfdFileName, to: 14, in: statement)
        try bind(entry.filePath, to: 15, in: statement)
        try bind(entry.fileName, to: 16, in: statement)
        try bind(entry.fileType, to: 17, in: statement)
        try bind(entry.fileBookmarkName, to: 18, in: statement)
        try bind(entry.fileCopyName, to: 19, in: statement)
        try bind(Int64(entry.isFavorite ? 1 : 0), to: 20, in: statement)
        try bind(entry.screenshotOrigin?.rawValue, to: 21, in: statement)
        try bind(entry.textRevision?.uuidString, to: 22, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        if let recording = entry.screenRecording {
            let metadata = try prepare("INSERT OR REPLACE INTO history_recording_metadata(entry_id, payload) VALUES (?, ?)")
            defer { sqlite3_finalize(metadata) }
            try bind(entry.id.uuidString, to: 1, in: metadata)
            try bind(String(data: JSONEncoder().encode(recording), encoding: .utf8), to: 2, in: metadata)
            guard sqlite3_step(metadata) == SQLITE_DONE else { throw failure() }
        }
        if entry.isFavorite { try writeFavoriteMembership(for: entry) }
        let insertTime = try prepare("INSERT OR IGNORE INTO history_record_times (entry_id, recorded_at) VALUES (?, ?)")
        defer { sqlite3_finalize(insertTime) }
        for date in entry.calendarRecordTimes {
            sqlite3_reset(insertTime)
            sqlite3_clear_bindings(insertTime)
            try bind(entry.id.uuidString, to: 1, in: insertTime)
            try bind(date.timeIntervalSince1970, to: 2, in: insertTime)
            guard sqlite3_step(insertTime) == SQLITE_DONE else { throw failure() }
        }
        if entry.kind == .group {
            let deleteMembers = try prepare("DELETE FROM history_group_members WHERE group_id = ?")
            defer { sqlite3_finalize(deleteMembers) }
            try bind(entry.id.uuidString, to: 1, in: deleteMembers)
            guard sqlite3_step(deleteMembers) == SQLITE_DONE else { throw failure() }
            let insertMember = try prepare(
                "INSERT INTO history_group_members (group_id, member_id, position) VALUES (?, ?, ?)"
            )
            defer { sqlite3_finalize(insertMember) }
            for (position, memberID) in entry.groupMemberIDs.enumerated() {
                sqlite3_reset(insertMember)
                sqlite3_clear_bindings(insertMember)
                try bind(entry.id.uuidString, to: 1, in: insertMember)
                try bind(memberID.uuidString, to: 2, in: insertMember)
                try bind(Int64(position), to: 3, in: insertMember)
                guard sqlite3_step(insertMember) == SQLITE_DONE else { throw failure() }
            }
        }
    }

    func favoriteCategories() throws -> [ClipboardFavoriteCategory] {
        let statement = try prepare("SELECT id, name, tint, icon FROM history_favorite_categories ORDER BY position")
        defer { sqlite3_finalize(statement) }
        var categories: [ClipboardFavoriteCategory] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return categories }
            guard step == SQLITE_ROW else { throw failure() }
            guard let id = string(statement, column: 0).flatMap(UUID.init(uuidString:)),
                  let name = string(statement, column: 1) else {
                throw ClipboardHistoryDatabaseError.invalidRecord
            }
            categories.append(ClipboardFavoriteCategory(
                id: id, name: name,
                tint: string(statement, column: 2).flatMap(ClipboardFavoriteCategory.Tint.init(rawValue:)) ?? .blue,
                icon: string(statement, column: 3).flatMap(ClipboardFavoriteCategory.Icon.init(rawValue:)) ?? .star
            ))
        }
    }

    func saveFavoriteCategory(_ category: ClipboardFavoriteCategory) throws {
        let statement = try prepare("""
            INSERT INTO history_favorite_categories (id, name, tint, icon) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, tint = excluded.tint, icon = excluded.icon
            """)
        defer { sqlite3_finalize(statement) }
        try bind(category.id.uuidString, to: 1, in: statement)
        try bind(category.name, to: 2, in: statement)
        try bind(category.tint.rawValue, to: 3, in: statement)
        try bind(category.icon.rawValue, to: 4, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func deleteFavoriteCategory(_ id: UUID) throws {
        let statement = try prepare("DELETE FROM history_favorite_categories WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        try deleteCardOrder(scope: "favorite:\(id.uuidString)")
    }

    func saveCardOrder(_ entries: [ClipboardEntry], scope: String) throws {
        try deleteCardOrder(scope: scope)
        let statement = try prepare("INSERT INTO history_card_order (scope, entry_id, position, copied_at) VALUES (?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        for (position, entry) in entries.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(scope, to: 1, in: statement)
            try bind(entry.id.uuidString, to: 2, in: statement)
            try bind(Int64(position), to: 3, in: statement)
            try bind(entry.createdAt.timeIntervalSince1970, to: 4, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }

    private func deleteCardOrder(scope: String) throws {
        let statement = try prepare("DELETE FROM history_card_order WHERE scope = ?")
        defer { sqlite3_finalize(statement) }
        try bind(scope, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func saveShelfPinOrder(_ ids: [UUID]) throws {
        // Positions are UNIQUE. Remove the participating rows before inserting
        // their new ranks, all within the caller's transaction, so swaps never
        // collide with another card's old position.
        let deletion = try prepare("DELETE FROM history_shelf_pins WHERE entry_id = ?")
        defer { sqlite3_finalize(deletion) }
        for id in ids {
            sqlite3_reset(deletion)
            sqlite3_clear_bindings(deletion)
            try bind(id.uuidString, to: 1, in: deletion)
            guard sqlite3_step(deletion) == SQLITE_DONE, let handle,
                  sqlite3_changes(handle) == 1 else { throw failure() }
        }
        let insertion = try prepare("INSERT INTO history_shelf_pins (entry_id, position) VALUES (?, ?)")
        defer { sqlite3_finalize(insertion) }
        for (index, id) in ids.enumerated() {
            sqlite3_reset(insertion)
            sqlite3_clear_bindings(insertion)
            try bind(id.uuidString, to: 1, in: insertion)
            try bind(Int64(ids.count - index), to: 2, in: insertion)
            guard sqlite3_step(insertion) == SQLITE_DONE else { throw failure() }
        }
    }

    private func writeFavoriteMembership(for entry: ClipboardEntry) throws {
        let statement: OpaquePointer
        if let categoryID = entry.favoriteCategoryID {
            statement = try prepare("""
                INSERT INTO history_favorite_members (entry_id, category_id) VALUES (?, ?)
                ON CONFLICT(entry_id) DO UPDATE SET category_id = excluded.category_id
                """)
            defer { sqlite3_finalize(statement) }
            try bind(entry.id.uuidString, to: 1, in: statement)
            try bind(categoryID.uuidString, to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        } else {
            statement = try prepare("DELETE FROM history_favorite_members WHERE entry_id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(entry.id.uuidString, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        }
    }

    func setShelfPinned(_ pinned: Bool, for id: UUID) throws -> Int64? {
        let statement = try prepare(pinned ? """
            INSERT INTO history_shelf_pins (entry_id, position)
            VALUES (?, (SELECT COALESCE(MAX(position), 0) + 1 FROM history_shelf_pins))
            ON CONFLICT(entry_id) DO UPDATE SET position = history_shelf_pins.position
            RETURNING position
            """ : "DELETE FROM history_shelf_pins WHERE entry_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        var position: Int64?
        if pinned {
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            position = sqlite3_column_int64(statement, 0)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return position
    }

    func delete(_ id: UUID) throws {
        let statement = try prepare("DELETE FROM history_entries WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func deleteAll() throws {
        try execute("DELETE FROM history_entries")
    }

    private func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int(statement, 0)
    }

    private func execute(_ sql: String) throws {
        guard let handle, sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw failure()
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw ClipboardHistoryDatabaseError.openFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw failure() }
        return statement
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        let code: Int32 = value.map { value in
            value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
        } ?? sqlite3_bind_null(statement, index)
        guard code == SQLITE_OK else { throw failure() }
    }

    private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) throws {
        let code = value.map { sqlite3_bind_double(statement, index, $0) }
            ?? sqlite3_bind_null(statement, index)
        guard code == SQLITE_OK else { throw failure() }
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) throws {
        let code = value.map { sqlite3_bind_int64(statement, index, $0) }
            ?? sqlite3_bind_null(statement, index)
        guard code == SQLITE_OK else { throw failure() }
    }

    private func string(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func failure() -> ClipboardHistoryDatabaseError {
        ClipboardHistoryDatabaseError.operationFailed(handle.map(sqlite3_errcode) ?? SQLITE_MISUSE)
    }
}
