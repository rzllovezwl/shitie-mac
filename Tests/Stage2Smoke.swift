import AppKit
import CryptoKit
import Foundation
import SQLite3

private enum Stage2TestError: Error { case failed(String) }

@main
struct Stage2Smoke {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookStage2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ClipHoookStage2-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Stage2TestError.failed("无法建立隔离设置") }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HistoryRetention.forever.rawValue, forKey: HistoryStoragePolicy.retentionKey)
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = root.appendingPathComponent("history")
        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let code = "    if ready {\n\tprint(\"保留格式\")\n    }\n\n"
        let attributed = NSAttributedString(string: code, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let html = Data("<pre><b>\(code)</b></pre>".utf8)
        try check(try store.addRichText(code, rtf: rtf, html: html, rtfd: nil,
                                        sourceAppName: "编辑器", sourceAppBundleID: "app.editor"), "保存富文本失败")
        let rich = store.entries[0]
        try check(rich.hasRichText && rich.text == code, "富文本原文被改写")
        try check(ClipboardPasteboardWriter.write(rich, from: store, to: board), "富文本回写剪贴板失败")
        try check(board.string(forType: .string) == code, "回写后代码缩进或结尾空行改变")
        try check(board.data(forType: .rtf) == rtf && board.data(forType: .html) == html,
                  "RTF/HTML 没有原样回写")
        try check(ClipboardPasteboardWriter.write(rich, from: store, to: board, mode: .plainText),
                  "富文本无法用纯文本模式回写")
        try check(board.string(forType: .string) == code
                  && board.data(forType: .rtf) == nil
                  && board.data(forType: .html) == nil,
                  "纯文本粘贴应保留代码空白字符且不携带格式")
        now.addTimeInterval(20)
        _ = try store.addRichText(code, rtf: rtf, html: html, rtfd: nil,
                                  sourceAppName: "另一个编辑器", sourceAppBundleID: "app.other")
        try check(store.entries.count == 1 && store.entries[0].id == rich.id
                  && store.entries[0].copyCount == 2 && store.entries[0].firstCopiedAt == rich.firstCopiedAt,
                  "同样格式重复复制未合并")
        _ = try store.addText(code, sourceAppName: "纯文本", sourceAppBundleID: "app.plain")
        try check(store.entries.count == 2, "相同文字但不同格式被错误合并")
        let reloaded = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        guard let restoredRich = reloaded.entries.first(where: { $0.id == rich.id }) else {
            throw Stage2TestError.failed("重启后富文本丢失")
        }
        let representations = reloaded.richTextData(for: restoredRich)
        try check(restoredRich.text == code && representations.rtf == rtf && representations.html == html,
                  "重启后原文或富文本表示变化")

        let original = root.appendingPathComponent("原文件.txt")
        let fileData = Data(repeating: 0x42, count: 2_100_000)
        try fileData.write(to: original)
        let beforeReferenceBytes = reloaded.activeStorageBytes
        _ = try reloaded.addFileReference(original, sourceAppName: "访达", sourceAppBundleID: "com.apple.finder")
        let reference = reloaded.entries[0]
        try check(reference.kind == .fileReference && reference.fileName == "原文件.txt"
                  && reference.fileType != nil, "文件名称或类型未保存")
        try check(!reloaded.fileHasSavedCopy(reference)
                  && reloaded.activeStorageBytes - beforeReferenceBytes < 1_000_000,
                  "位置引用错误保存了文件内容")
        try check(ClipboardPasteboardWriter.write(reference, from: reloaded, to: board), "文件位置无法回写剪贴板")
        try check(!ClipboardPasteboardWriter.write(reference, from: reloaded, to: board, mode: .plainText),
                  "文件引用不应被当成纯文本粘贴")
        let copiedURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        try check(copiedURLs.compactMap { $0 as? URL }.contains(where: {
            $0.resolvingSymlinksInPath().path == original.resolvingSymlinksInPath().path
        }),
                  "剪贴板没有原文件 URL：types=\(board.pasteboardItems?.first?.types ?? [])，objects=\(copiedURLs)")

        try await reloaded.saveFileCopy(for: reference)
        guard let withCopy = reloaded.entries.first(where: { $0.id == reference.id }) else {
            throw Stage2TestError.failed("保存副本后记录丢失")
        }
        try check(reloaded.fileHasSavedCopy(withCopy) && reloaded.activeStorageBytes > beforeReferenceBytes + 2_000_000,
                  "文件副本未计入实际占用")
        try FileManager.default.removeItem(at: original)
        try check(reloaded.fileReferenceIsAvailable(withCopy)
                  && reloaded.withUsableFileURL(for: withCopy, { (try? Data(contentsOf: $0)) == fileData }) == true,
                  "原文件删除后，保存的副本不可用")
        try check(ClipboardPasteboardWriter.write(withCopy, from: reloaded, to: board), "本地副本无法回写剪贴板")
        let copyPath = reloaded.withUsableFileURL(for: withCopy) { $0.path }
        try check(copyPath?.contains("FileCopies") == true, "保存副本后仍在使用原位置")
        let replacement = root.appendingPathComponent("搬走后的文件.txt")
        try Data("new snapshot".utf8).write(to: replacement)
        try await reloaded.saveFileCopy(for: withCopy, using: replacement)
        guard let withReplacement = reloaded.entries.first(where: { $0.id == reference.id }) else {
            throw Stage2TestError.failed("更新副本后记录丢失")
        }
        try check(withReplacement.filePath == original.path
                  && reloaded.savedCopyDisplayName(for: withReplacement) == "搬走后的文件.txt"
                  && reloaded.withUsableFileURL(for: withReplacement, {
                      (try? String(contentsOf: $0, encoding: .utf8)) == "new snapshot"
                  }) == true,
                  "更新副本改写了原位置或没有更新副本")
        let activeCopy = reloaded.withUsableFileURL(for: withReplacement) { $0.path }
        try check(copyPath.map { !FileManager.default.fileExists(atPath: $0) } == true,
                  "更新副本后旧副本仍占用空间")
        try reloaded.delete(withReplacement)
        try check(activeCopy.map { !FileManager.default.fileExists(atPath: $0) } == true,
                  "删除记录未删除本地副本")

        let untouched = root.appendingPathComponent("不应删除.txt")
        try Data("keep".utf8).write(to: untouched)
        _ = try reloaded.addFileReference(untouched, sourceAppName: nil)
        let untouchedEntry = reloaded.entries[0]
        try reloaded.delete(untouchedEntry)
        try check(FileManager.default.fileExists(atPath: untouched.path), "删除位置引用误删原文件")

        let missing = root.appendingPathComponent("稍后删除.txt")
        try Data("missing".utf8).write(to: missing)
        _ = try reloaded.addFileReference(missing, sourceAppName: nil)
        let missingEntry = reloaded.entries[0]
        try FileManager.default.removeItem(at: missing)
        let priorPasteboard = board.string(forType: .string)
        try check(!reloaded.fileReferenceIsAvailable(missingEntry)
                  && !ClipboardPasteboardWriter.write(missingEntry, from: reloaded, to: board)
                  && board.string(forType: .string) == priorPasteboard,
                  "失效引用不应假装复制成功或清空原剪贴板")

        try testVersionOneUpgrade(root: root, defaults: defaults, now: now)
        print("Stage2Smoke passed")
    }

    @MainActor
    private static func testVersionOneUpgrade(root: URL, defaults: UserDefaults, now: Date) throws {
        let folder = root.appendingPathComponent("version1")
        let content = folder.appendingPathComponent("Content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let id = UUID()
        let text = "旧记录\n\t"
        try text.write(to: content.appendingPathComponent("\(id.uuidString).txt"), atomically: true, encoding: .utf8)
        let databaseURL = folder.appendingPathComponent("history.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw Stage2TestError.failed("无法创建旧版数据库夹具")
        }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE history_entries (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, digest TEXT NOT NULL UNIQUE,
                first_copied_at REAL, last_copied_at REAL NOT NULL, copy_count INTEGER,
                image_file_name TEXT, image_pasteboard_type TEXT, byte_count INTEGER NOT NULL,
                source_app_name TEXT, source_app_bundle_id TEXT
            );
            PRAGMA user_version = 1;
            INSERT INTO history_entries (
                id, kind, digest, last_copied_at, byte_count, source_app_name
            ) VALUES ('\(id.uuidString)', 'text', 'old-digest', \(now.timeIntervalSince1970), \(text.utf8.count), '旧应用');
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw Stage2TestError.failed("旧版数据库夹具写入失败")
        }
        sqlite3_close(db)
        db = nil
        let upgraded = ClipboardHistoryStore(directory: folder, defaults: defaults, now: { now })
        try check(upgraded.errorMessage == nil && upgraded.entries.count == 1
                  && upgraded.entries[0].text == text && upgraded.entries[0].sourceAppName == "旧应用",
                  "旧数据库升级破坏记录")
        _ = try upgraded.addFileReference(root.appendingPathComponent("不存在.txt"), sourceAppName: nil)
        try check(upgraded.entries.count == 2, "升级后无法写入新类型")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Stage2TestError.failed(message) }
    }
}
