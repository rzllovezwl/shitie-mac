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
            guard version <= 3 else {
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

    func entries(contentDirectory: URL) throws -> [ClipboardEntry] {
        let statement = try prepare("""
            SELECT id, kind, digest, first_copied_at, last_copied_at, copy_count,
                   image_file_name, image_pasteboard_type, byte_count,
                   source_app_name, source_app_bundle_id,
                   rtf_file_name, html_file_name, rtfd_file_name,
                   file_path, file_name, file_type, file_bookmark_name, file_copy_name
            FROM history_entries ORDER BY last_copied_at DESC
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
            let text = kind == .image || kind == .unavailableImage
                || kind == .fileReference || kind == .group ? nil : try? String(
                contentsOf: contentDirectory.appendingPathComponent("\(id.uuidString).txt"),
                encoding: .utf8
            )
            var entry = ClipboardEntry(
                id: id,
                createdAt: lastCopiedAt,
                firstCopiedAt: firstCopiedAt,
                copyCount: copyCount,
                kind: kind,
                text: text,
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
            result.append(entry)
        }
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
        return result
    }

    func upsert(_ entry: ClipboardEntry) throws {
        guard entry.kind == .group else {
            try upsertRecordAndMembers(entry)
            return
        }
        // A group refresh rewrites its ordered membership. Keep it atomic even
        // when the caller is not already in a batch transaction.
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
                file_path, file_name, file_type, file_bookmark_name, file_copy_name
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                file_copy_name = excluded.file_copy_name
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
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
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
