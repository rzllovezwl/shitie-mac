import CryptoKit
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import AppKit

/// Keeps a security-scoped original accessible while Quick Look renders it.
/// A saved copy lives in our own storage and needs no security scope.
final class FilePreviewAccess {
    let url: URL
    private let startedSecurityScope: Bool

    init?(url: URL, usesSecurityScope: Bool) {
        let started = usesSecurityScope && url.startAccessingSecurityScopedResource()
        guard (try? url.checkResourceIsReachable()) == true,
              FileManager.default.isReadableFile(atPath: url.path) else {
            if started { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        self.url = url
        startedSecurityScope = started
    }

    deinit {
        if startedSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

enum ClipboardHistoryStoreError: LocalizedError {
    case unavailable, invalidLegacyRecord, migrationVerificationFailed, legacyWriterDetected, invalidSavedRecord
    case fileReferenceUnavailable, fileCopyExceedsLimit, unsupportedFile
    case invalidBatch

    var errorDescription: String? {
        switch self {
        case .unavailable: "历史记录尚未准备好；旧记录未被修改。"
        case .invalidLegacyRecord: "旧记录或图片不完整，迁移已停止。"
        case .migrationVerificationFailed: "历史记录迁移校验失败，旧记录未被修改。"
        case .legacyWriterDetected: "检测到旧版仍在写入 history.json；请先退出旧版，避免两份历史分叉。"
        case .invalidSavedRecord: "已保存记录的内容位置无效。"
        case .fileReferenceUnavailable: "原文件已移动、删除或无法访问；请重新选择文件。"
        case .fileCopyExceedsLimit: "文件副本超过设置的最大存储量；请调整上限后重试。"
        case .unsupportedFile: "目前只能保存普通文件的副本，不能保存文件夹或符号链接。"
        case .invalidBatch: "这批内容无法完整保存；系统剪贴板内容未受影响。"
        }
    }
}

/// The previous JSON schema. Unknown original copy dates/counts stay unknown.
private struct LegacyClipboardEntry: Decodable {
    let id: UUID
    let createdAt: Date
    let kind: String
    let text: String?
    let imageFileName: String?
    let imagePasteboardType: String?
    let digest: String
    let byteCount: Int
    let sourceAppName: String?

    var current: ClipboardEntry? {
        guard let currentKind = ClipboardEntry.Kind(rawValue: kind) else { return nil }
        return ClipboardEntry(
            id: id, createdAt: createdAt, firstCopiedAt: nil, copyCount: nil,
            kind: currentKind, text: text, imageFileName: imageFileName,
            imagePasteboardType: imagePasteboardType, digest: digest,
            byteCount: byteCount, sourceAppName: sourceAppName, sourceAppBundleID: nil
        )
    }
}

@MainActor
final class ClipboardHistoryStore {
    private let fileManager = FileManager.default
    private let directory: URL
    private let imagesDirectory: URL
    private let contentDirectory: URL
    private let richTextDirectory: URL
    private let bookmarksDirectory: URL
    private let fileCopiesDirectory: URL
    private let thumbnailsDirectory: URL
    private let databaseURL: URL
    private let legacyIndexURL: URL
    private let migrationBackupURL: URL
    private let recoveryDirectory: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar
    private var database: ClipboardHistoryDatabase?
    private var batchInProgress = false
    private var lastInsertedID: UUID?
    /// Captured before the store creates its support directory. Existing users
    /// should discover new features in the shelf without a first-run popup.
    let isNewInstallation: Bool

    private(set) var entries: [ClipboardEntry] = []
    private(set) var errorMessage: String?
    let maximumImageBytes = 15 * 1_024 * 1_024
    let maximumTextBytes = 32 * 1_024 * 1_024
    let maximumRichTextBytes = 15 * 1_024 * 1_024

    var rootEntries: [ClipboardEntry] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        // Keep a copied batch visible as one expandable card even when a
        // member's image bytes could not be read. The missing member remains a
        // placeholder inside the group and cannot be copied as image data.
        let visibleGroups = Set(entries.filter { group in
            group.kind == .group && group.groupMemberIDs.count > 1 &&
                group.groupMemberIDs.allSatisfy { byID[$0] != nil }
        }.map(\.id))
        var lastGroupedAt: [UUID: Date] = [:]
        for group in entries where visibleGroups.contains(group.id) {
            for id in group.groupMemberIDs {
                lastGroupedAt[id] = max(lastGroupedAt[id] ?? .distantPast, group.createdAt)
            }
        }
        return entries.compactMap { entry in
            if let groupedAt = lastGroupedAt[entry.id], entry.createdAt <= groupedAt {
                return nil
            }
            guard entry.kind == .group else { return entry }
            guard visibleGroups.contains(entry.id) else { return nil }
            var group = entry
            group.groupMembers = group.groupMemberIDs.compactMap { byID[$0] }
            return group
        }
    }

    init(
        directory overrideDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.defaults = defaults
        self.now = now
        self.calendar = calendar
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = overrideDirectory ?? support.appendingPathComponent("ClipboardShelf", isDirectory: true)
        isNewInstallation = !fileManager.fileExists(atPath: directory.path)
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        contentDirectory = directory.appendingPathComponent("Content", isDirectory: true)
        richTextDirectory = directory.appendingPathComponent("RichText", isDirectory: true)
        bookmarksDirectory = directory.appendingPathComponent("Bookmarks", isDirectory: true)
        fileCopiesDirectory = directory.appendingPathComponent("FileCopies", isDirectory: true)
        thumbnailsDirectory = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        legacyIndexURL = directory.appendingPathComponent("history.json")
        migrationBackupURL = directory.appendingPathComponent("LegacyMigrationBackup", isDirectory: true)
        recoveryDirectory = directory.appendingPathComponent("UnreferencedRecovery", isDirectory: true)
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: richTextDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: bookmarksDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: fileCopiesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: databaseURL.path),
               fileManager.fileExists(atPath: legacyIndexURL.path) {
                try migrateLegacyHistory()
            }
            if fileManager.fileExists(atPath: legacyIndexURL.path) {
                throw ClipboardHistoryStoreError.legacyWriterDetected
            }
            database = try ClipboardHistoryDatabase(url: databaseURL)
            entries = try requiredDatabase().entries(contentDirectory: contentDirectory)
            try moveUnreferencedPayloadsToRecovery()
            _ = try pruneEntries()
        } catch {
            database = nil
            // Never present a failed migration as an empty, writable history.
            if let data = try? Data(contentsOf: legacyIndexURL),
               let legacy = try? JSONDecoder().decode([LegacyClipboardEntry].self, from: data) {
                entries = legacy.compactMap(\.current).sorted { $0.createdAt > $1.createdAt }
            }
            errorMessage = "无法读取历史记录：\(error.localizedDescription)"
        }
    }

    var activeStorageBytes: Int64 {
        diskBytes(at: databaseURL) + diskBytes(in: contentDirectory) + diskBytes(in: imagesDirectory)
            + diskBytes(in: richTextDirectory) + diskBytes(in: bookmarksDirectory)
            + diskBytes(in: fileCopiesDirectory) + diskBytes(in: thumbnailsDirectory)
    }

    var migrationBackupBytes: Int64 { diskBytes(in: migrationBackupURL) }
    var recoveryBytes: Int64 { diskBytes(in: recoveryDirectory) }
    var pinnedImagesDirectory: URL { directory.appendingPathComponent("PinnedImages", isDirectory: true) }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let name = entry.imageFileName, safeFileName(name) else { return nil }
        let url = imagesDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnailURL(for entry: ClipboardEntry) -> URL? {
        guard entry.kind == .fileReference else { return nil }
        let url = thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func fileHasSavedCopy(_ entry: ClipboardEntry) -> Bool {
        savedCopyURL(for: entry) != nil
    }

    func savedCopyDisplayName(for entry: ClipboardEntry) -> String? {
        guard let name = entry.fileCopyName, savedCopyURL(for: entry) != nil else { return nil }
        return String(name.dropFirst(37))
    }

    func fileReferenceIsAvailable(_ entry: ClipboardEntry) -> Bool {
        withUsableFileURL(for: entry) { (try? $0.checkResourceIsReachable()) == true } ?? false
    }

    func filePreviewAccess(for entry: ClipboardEntry) -> FilePreviewAccess? {
        guard entry.kind == .fileReference else { return nil }
        if let copy = savedCopyURL(for: entry) {
            return FilePreviewAccess(url: copy, usesSecurityScope: false)
        }
        guard let original = resolvedOriginalURL(for: entry) else { return nil }
        return FilePreviewAccess(url: original, usesSecurityScope: true)
    }

    func originalFileIsAvailable(_ entry: ClipboardEntry) -> Bool {
        withOriginalFileURL(for: entry) { _ in true } ?? false
    }

    func withOriginalFileURL<T>(for entry: ClipboardEntry, _ work: (URL) -> T) -> T? {
        guard entry.kind == .fileReference else { return nil }
        guard let url = resolvedOriginalURL(for: entry) else { return nil }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.checkResourceIsReachable()) == true,
              fileManager.isReadableFile(atPath: url.path) else { return nil }
        return work(url)
    }

    func withUsableFileURL<T>(for entry: ClipboardEntry, _ work: (URL) -> T) -> T? {
        guard entry.kind == .fileReference else { return nil }
        if let copy = savedCopyURL(for: entry) { return work(copy) }
        guard let original = resolvedOriginalURL(for: entry) else { return nil }
        let started = original.startAccessingSecurityScopedResource()
        defer { if started { original.stopAccessingSecurityScopedResource() } }
        guard (try? original.checkResourceIsReachable()) == true,
              fileManager.isReadableFile(atPath: original.path) else { return nil }
        return work(original)
    }

    func richTextData(for entry: ClipboardEntry) -> (rtf: Data?, html: Data?, rtfd: Data?) {
        func read(_ name: String?) -> Data? {
            guard let name, safeFileName(name) else { return nil }
            return try? Data(contentsOf: richTextDirectory.appendingPathComponent(name))
        }
        return (read(entry.rtfFileName), read(entry.htmlFileName), read(entry.rtfdFileName))
    }

    func richTextSourceFiles(for entry: ClipboardEntry) -> RichTextSourceFiles {
        func url(_ name: String?) -> URL? {
            guard let name, safeFileName(name) else { return nil }
            let candidate = richTextDirectory.appendingPathComponent(name)
            return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
        }
        return RichTextSourceFiles(
            rtf: url(entry.rtfFileName),
            html: url(entry.htmlFileName),
            rtfd: url(entry.rtfdFileName)
        )
    }

    func requestThumbnail(for entry: ClipboardEntry, completion: @escaping () -> Void) {
        guard entry.kind == .fileReference,
              entries.contains(where: { $0.id == entry.id }),
              thumbnailURL(for: entry) == nil else { return }
        let url = savedCopyURL(for: entry) ?? resolvedOriginalURL(for: entry)
        guard let url else { return }
        let started = url.startAccessingSecurityScopedResource()
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 320, height: 240), scale: 2,
            representationTypes: .thumbnail
        )
        let output = thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png")
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            if started { url.stopAccessingSecurityScopedResource() }
            Task { @MainActor in
                if self.entries.contains(where: { $0.id == entry.id }),
                   (self.savedCopyURL(for: entry) ?? self.resolvedOriginalURL(for: entry))?.path == url.path,
                   let image = representation?.nsImage,
                   let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: output, options: .atomic)
                    _ = try? self.pruneEntries()
                }
                completion()
            }
        }
    }

    func addText(
        _ text: String, sourceAppName: String?, sourceAppBundleID: String? = nil,
        occurrence: Int = 0
    ) throws -> Bool {
        guard !text.isEmpty else { return false }
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else { return false }
        _ = try requiredDatabase()
        let kind: ClipboardEntry.Kind = Self.isWebLink(text) ? .link : .text
        let digest = Self.digest(data: data, prefix: Self.batchPrefix(kind.rawValue, occurrence: occurrence))
        if let old = entries.first(where: { $0.digest == digest }),
           !fileManager.fileExists(atPath: textURL(for: old.id).path) {
            try data.write(to: textURL(for: old.id), options: .atomic)
        }
        if try refreshExisting(digest: digest, sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID) {
            _ = try pruneEntries()
            return true
        }
        let date = now()
        let entry = ClipboardEntry(
            id: UUID(), createdAt: date, firstCopiedAt: date, copyCount: 1,
            kind: kind, text: text, imageFileName: nil, imagePasteboardType: nil,
            digest: digest, byteCount: data.count, sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
        let url = textURL(for: entry.id)
        try data.write(to: url, options: .atomic)
        do { try requiredDatabase().upsert(entry) }
        catch { try? fileManager.removeItem(at: url); throw error }
        insertNewestFirst(entry)
        _ = try pruneEntries()
        return true
    }

    func addImage(
        _ data: Data, type: String, sourceAppName: String?, sourceAppBundleID: String? = nil,
        occurrence: Int = 0
    ) throws -> Bool {
        guard !data.isEmpty, data.count <= maximumImageBytes else { return false }
        _ = try requiredDatabase()
        let digest = Self.digest(data: data, prefix: Self.batchPrefix("image", occurrence: occurrence))
        if let old = entries.first(where: { $0.digest == digest }) {
            guard let name = old.imageFileName, safeFileName(name) else {
                throw ClipboardHistoryStoreError.invalidSavedRecord
            }
            let oldURL = imagesDirectory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: oldURL.path) {
                try data.write(to: oldURL, options: .atomic)
            }
        }
        if try refreshExisting(digest: digest, sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID) {
            _ = try pruneEntries()
            return true
        }
        let id = UUID()
        let name = "\(id.uuidString).\(Self.imageExtension(for: type))"
        let url = imagesDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let date = now()
        let entry = ClipboardEntry(
            id: id, createdAt: date, firstCopiedAt: date, copyCount: 1,
            kind: .image, text: nil, imageFileName: name, imagePasteboardType: type,
            digest: digest, byteCount: data.count, sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
        do { try requiredDatabase().upsert(entry) }
        catch { try? fileManager.removeItem(at: url); throw error }
        insertNewestFirst(entry)
        _ = try pruneEntries()
        return true
    }

    /// Screenshots sent by an iPhone are imports, not clipboard copy events.
    /// Repeated delivery of the same bytes must neither create another card
    /// nor increase the copy counter of an existing image.
    func importPhoneScreenshot(_ data: Data, type: String) throws -> Bool {
        guard !data.isEmpty, data.count <= maximumImageBytes else { return false }
        _ = try requiredDatabase()
        let digest = Self.digest(data: data, prefix: "image")
        if let index = entries.firstIndex(where: { $0.digest == digest }) {
            let existing = entries[index]
            if let name = existing.imageFileName, safeFileName(name) {
                let url = imagesDirectory.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: url.path) {
                    try data.write(to: url, options: .atomic)
                }
            }
            // The same bytes may already have arrived through Universal
            // Clipboard or a Mac app while the iPhone upload was in flight.
            // Keep one card and its real copy count, but show the latest
            // acquisition channel instead of a misleading foreground app.
            guard existing.sourceAppName != "iPhone 截图" ||
                    existing.sourceAppBundleID != nil else { return false }
            var updated = existing
            updated.createdAt = max(now(), (entries.first?.createdAt ?? .distantPast).addingTimeInterval(0.001))
            updated.sourceAppName = "iPhone 截图"
            updated.sourceAppBundleID = nil
            try requiredDatabase().upsert(updated)
            entries.remove(at: index)
            insertNewestFirst(updated)
            return true
        }
        let id = UUID()
        let name = "\(id.uuidString).\(Self.imageExtension(for: type))"
        let url = imagesDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let receivedAt = max(now(), (entries.first?.createdAt ?? .distantPast).addingTimeInterval(0.001))
        let entry = ClipboardEntry(
            id: id, createdAt: receivedAt, firstCopiedAt: nil, copyCount: nil,
            kind: .image, text: nil, imageFileName: name, imagePasteboardType: type,
            digest: digest, byteCount: data.count, sourceAppName: "iPhone 截图",
            sourceAppBundleID: nil
        )
        do { try requiredDatabase().upsert(entry) }
        catch { try? fileManager.removeItem(at: url); throw error }
        insertNewestFirst(entry)
        _ = try pruneEntries()
        return true
    }

    func addRichText(
        _ text: String, rtf: Data?, html: Data?, rtfd: Data?,
        sourceAppName: String?, sourceAppBundleID: String? = nil,
        occurrence: Int = 0
    ) throws -> Bool {
        guard !text.isEmpty else { return false }
        let textData = Data(text.utf8)
        guard textData.count <= maximumTextBytes else { return false }
        let formats = [rtf, html, rtfd]
        guard formats.contains(where: { $0 != nil }),
              formats.reduce(0, { $0 + ($1?.count ?? 0) }) <= maximumRichTextBytes else {
            return try addText(text, sourceAppName: sourceAppName,
                               sourceAppBundleID: sourceAppBundleID, occurrence: occurrence)
        }
        _ = try requiredDatabase()
        var signature = Data("rich-text\0".utf8)
        for (label, data) in zip(["plain", "rtf", "html", "rtfd"], [textData, rtf, html, rtfd]) {
            signature.append(contentsOf: label.utf8)
            signature.append(0)
            if let data {
                var length = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &length) { signature.append(contentsOf: $0) }
                signature.append(data)
            } else {
                signature.append(contentsOf: Array(repeating: 0, count: 8))
            }
        }
        let kind: ClipboardEntry.Kind = Self.isWebLink(text) ? .link : .text
        let digest = Self.digest(data: signature, prefix: Self.batchPrefix("rich", occurrence: occurrence))
        if let old = entries.first(where: { $0.digest == digest }) {
            let oldText = textURL(for: old.id)
            if !fileManager.fileExists(atPath: oldText.path) { try textData.write(to: oldText, options: .atomic) }
            for (name, data) in [(old.rtfFileName, rtf), (old.htmlFileName, html), (old.rtfdFileName, rtfd)] {
                guard let name, safeFileName(name), let data else { continue }
                let url = richTextDirectory.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
            }
            _ = try refreshExisting(digest: digest, sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID)
            _ = try pruneEntries()
            return true
        }
        let id = UUID()
        let date = now()
        var entry = ClipboardEntry(
            id: id, createdAt: date, firstCopiedAt: date, copyCount: 1,
            kind: kind, text: text, imageFileName: nil, imagePasteboardType: nil,
            digest: digest, byteCount: textData.count + formats.reduce(0, { $0 + ($1?.count ?? 0) }),
            sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID
        )
        entry.rtfFileName = rtf.map { _ in "\(id.uuidString).rtf" }
        entry.htmlFileName = html.map { _ in "\(id.uuidString).html" }
        entry.rtfdFileName = rtfd.map { _ in "\(id.uuidString).rtfd" }
        let files: [(URL, Data)] = [(textURL(for: id), textData)] +
            [(entry.rtfFileName, rtf), (entry.htmlFileName, html), (entry.rtfdFileName, rtfd)]
                .compactMap { name, data in
                    guard let name, let data else { return nil }
                    return (richTextDirectory.appendingPathComponent(name), data)
                }
        do {
            for (url, data) in files { try data.write(to: url, options: .atomic) }
            try requiredDatabase().upsert(entry)
        } catch {
            for (url, _) in files { try? fileManager.removeItem(at: url) }
            throw error
        }
        insertNewestFirst(entry)
        _ = try pruneEntries()
        return true
    }

    func addFileReference(
        _ fileURL: URL, sourceAppName: String?, sourceAppBundleID: String? = nil,
        occurrence: Int = 0
    ) throws -> Bool {
        guard fileURL.isFileURL else { return false }
        _ = try requiredDatabase()
        let normalized = fileURL.standardizedFileURL
        let digest = Self.digest(data: Data(normalized.path.utf8),
                                 prefix: Self.batchPrefix("file-reference", occurrence: occurrence))
        if try refreshExisting(digest: digest, sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID) {
            _ = try pruneEntries()
            return true
        }
        let id = UUID()
        let date = now()
        let values = try? normalized.resourceValues(forKeys: [.fileSizeKey])
        var entry = ClipboardEntry(
            id: id, createdAt: date, firstCopiedAt: date, copyCount: 1,
            kind: .fileReference, text: nil, imageFileName: nil, imagePasteboardType: nil,
            digest: digest, byteCount: values?.fileSize ?? 0,
            sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID
        )
        entry.filePath = normalized.path
        entry.fileName = normalized.lastPathComponent
        entry.fileType = UTType(filenameExtension: normalized.pathExtension)?.identifier
        if let bookmark = makeFileBookmark(for: normalized) {
            let name = "\(id.uuidString).bookmark"
            try bookmark.write(to: bookmarksDirectory.appendingPathComponent(name), options: .atomic)
            entry.fileBookmarkName = name
        }
        do { try requiredDatabase().upsert(entry) }
        catch {
            if let name = entry.fileBookmarkName {
                try? fileManager.removeItem(at: bookmarksDirectory.appendingPathComponent(name))
            }
            throw error
        }
        insertNewestFirst(entry)
        _ = try pruneEntries()
        return true
    }

    func addUnavailableImageReference(
        _ fileURL: URL, sourceAppName: String?, sourceAppBundleID: String?,
        occurrence: Int = 0
    ) throws -> Bool {
        guard fileURL.isFileURL else { return false }
        _ = try requiredDatabase()
        let normalized = fileURL.standardizedFileURL
        let digest = Self.digest(data: Data(normalized.path.utf8),
                                 prefix: Self.batchPrefix("unavailable-image", occurrence: occurrence))
        if try refreshExisting(digest: digest, sourceAppName: sourceAppName,
                               sourceAppBundleID: sourceAppBundleID) {
            _ = try pruneEntries()
            return true
        }
        let date = now()
        var entry = ClipboardEntry(
            id: UUID(), createdAt: date, firstCopiedAt: date, copyCount: 1,
            kind: .unavailableImage, text: nil, imageFileName: nil,
            imagePasteboardType: nil, digest: digest, byteCount: 0,
            sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID
        )
        entry.filePath = normalized.path
        entry.fileName = normalized.lastPathComponent
        entry.fileType = UTType(filenameExtension: normalized.pathExtension)?.identifier
        try requiredDatabase().upsert(entry)
        insertNewestFirst(entry)
        _ = try pruneEntries()
        return true
    }

    /// Saves one external clipboard change as a unit. Existing payloads keep
    /// their IDs, while the ordered group references them without copying data.
    func addCapturedBatch(
        _ captured: [ClipboardCapturedItem],
        sourceAppName: String?, sourceAppBundleID: String?,
        automaticallyGroup: Bool, preserveOccurrences: Bool = false
    ) throws -> Bool {
        guard !captured.isEmpty else { return false }
        let database = try requiredDatabase()
        let before = entries
        let oldIDs = Set(before.map(\.id))
        var savedIDs: [UUID] = []
        var occurrencesBySignature: [Int: Int] = [:]
        let occurrences = captured.map { item -> Int in
            guard preserveOccurrences else { return 0 }
            let signature = Self.batchOccurrenceSignature(for: item)
            let occurrence = occurrencesBySignature[signature, default: 0]
            occurrencesBySignature[signature] = occurrence + 1
            return occurrence
        }
        batchInProgress = true
        do {
            try database.transaction {
                // Every add inserts its result at the front. Reverse processing
                // retains the source application's item order on the shelf.
                for index in captured.indices.reversed() {
                    let item = captured[index]
                    let occurrence = occurrences[index]
                    let added: Bool
                    switch item {
                    case .text(let text):
                        added = try addText(text, sourceAppName: sourceAppName,
                                            sourceAppBundleID: sourceAppBundleID,
                                            occurrence: occurrence)
                    case .richText(let text, let rtf, let html, let rtfd):
                        added = try addRichText(text, rtf: rtf, html: html, rtfd: rtfd,
                                                sourceAppName: sourceAppName,
                                                sourceAppBundleID: sourceAppBundleID,
                                                occurrence: occurrence)
                    case .image(let data, let type):
                        added = try addImage(data, type: type, sourceAppName: sourceAppName,
                                             sourceAppBundleID: sourceAppBundleID,
                                             occurrence: occurrence)
                    case .unavailableImage(let url):
                        added = try addUnavailableImageReference(
                            url, sourceAppName: sourceAppName,
                            sourceAppBundleID: sourceAppBundleID,
                            occurrence: occurrence
                        )
                    case .fileReference(let url):
                        added = try addFileReference(url, sourceAppName: sourceAppName,
                                                      sourceAppBundleID: sourceAppBundleID,
                                                      occurrence: occurrence)
                    }
                    guard added, let id = lastInsertedID else {
                        throw ClipboardHistoryStoreError.invalidBatch
                    }
                    savedIDs.append(id)
                }
                if automaticallyGroup && savedIDs.count > 1 {
                    _ = try upsertGroup(
                        memberIDs: Array(savedIDs.reversed()),
                        sourceAppName: sourceAppName,
                        sourceAppBundleID: sourceAppBundleID
                    )
                }
            }
        } catch {
            batchInProgress = false
            let newEntries = entries.filter { !oldIDs.contains($0.id) }
            entries = before
            for entry in newEntries { try? removePayload(for: entry) }
            throw error
        }
        batchInProgress = false
        _ = try pruneEntries()
        return true
    }

    private static func batchPrefix(_ prefix: String, occurrence: Int) -> String {
        occurrence == 0 ? prefix : "\(prefix)-batch-occurrence-\(occurrence)"
    }

    private static func batchOccurrenceSignature(for item: ClipboardCapturedItem) -> Int {
        var hasher = Hasher()
        switch item {
        case .text(let text):
            hasher.combine(0)
            hasher.combine(text)
        case .richText(let text, let rtf, let html, let rtfd):
            hasher.combine(1)
            hasher.combine(text)
            hasher.combine(rtf)
            hasher.combine(html)
            hasher.combine(rtfd)
        case .image(let data, _):
            hasher.combine(2)
            hasher.combine(data)
        case .unavailableImage(let url):
            hasher.combine(3)
            hasher.combine(url.standardizedFileURL.path)
        case .fileReference(let url):
            hasher.combine(4)
            hasher.combine(url.standardizedFileURL.path)
        }
        return hasher.finalize()
    }

    /// Counts a successful in-panel multi-copy and optionally creates a group.
    /// The write to the system pasteboard has already succeeded at this point.
    func recordBatchCopy(of memberIDs: [UUID], automaticallyGroup: Bool) throws -> Bool {
        var seen: Set<UUID> = []
        let uniqueIDs = memberIDs.filter { seen.insert($0).inserted }
        guard memberIDs.count > 1, uniqueIDs.allSatisfy({ id in
            entries.contains { $0.id == id && $0.kind != .group }
        }) else { return false }
        let database = try requiredDatabase()
        let before = entries
        do {
            try database.transaction {
                for id in uniqueIDs.reversed() {
                    guard try recordCopy(of: id) else { throw ClipboardHistoryStoreError.invalidBatch }
                }
                if automaticallyGroup {
                    _ = try upsertGroup(
                        memberIDs: memberIDs,
                        sourceAppName: "ClipHoook",
                        sourceAppBundleID: Bundle.main.bundleIdentifier
                    )
                }
            }
            return true
        } catch {
            entries = before
            throw error
        }
    }

    private func upsertGroup(
        memberIDs: [UUID], sourceAppName: String?, sourceAppBundleID: String?
    ) throws -> UUID {
        guard memberIDs.count > 1 else { throw ClipboardHistoryStoreError.invalidBatch }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        guard memberIDs.allSatisfy({ byID[$0]?.kind != nil && byID[$0]?.kind != .group }) else {
            throw ClipboardHistoryStoreError.invalidBatch
        }
        let signature = memberIDs.map { byID[$0]!.digest }.joined(separator: "\n")
        let digest = Self.digest(data: Data(signature.utf8), prefix: "group")
        let date = max(now(), (entries.first?.createdAt ?? .distantPast).addingTimeInterval(0.001))
        if let index = entries.firstIndex(where: { $0.digest == digest && $0.kind == .group }) {
            var group = entries.remove(at: index)
            group.createdAt = date
            group.copyCount = (group.copyCount ?? 0) + 1
            group.sourceAppName = sourceAppName
            group.sourceAppBundleID = sourceAppBundleID
            try requiredDatabase().upsert(group)
            insertNewestFirst(group)
            return group.id
        }
        var group = ClipboardEntry(
            id: UUID(), createdAt: date, firstCopiedAt: date, copyCount: 1,
            kind: .group, text: nil, imageFileName: nil, imagePasteboardType: nil,
            digest: digest,
            byteCount: memberIDs.reduce(0) { $0 + (byID[$1]?.byteCount ?? 0) },
            sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID
        )
        group.groupMemberIDs = memberIDs
        try requiredDatabase().upsert(group)
        insertNewestFirst(group)
        return group.id
    }

    func saveFileCopy(for entry: ClipboardEntry, using replacement: URL? = nil) async throws {
        guard entries.contains(where: { $0.id == entry.id }),
              entry.kind == .fileReference else { throw ClipboardHistoryStoreError.invalidSavedRecord }
        let source = replacement ?? resolvedOriginalURL(for: entry)
        guard let source else { throw ClipboardHistoryStoreError.fileReferenceUnavailable }
        let started = source.startAccessingSecurityScopedResource()
        defer { if started { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ClipboardHistoryStoreError.unsupportedFile
        }
        guard fileManager.isReadableFile(atPath: source.path) else {
            throw ClipboardHistoryStoreError.fileReferenceUnavailable
        }
        if let maximum = HistoryStoragePolicy(defaults: defaults).maximumBytes,
           (values.fileSize ?? 0) > maximum {
            throw ClipboardHistoryStoreError.fileCopyExceedsLimit
        }
        let copyFolder = fileCopiesDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: copyFolder, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString)-\(source.lastPathComponent)"
        let destination = copyFolder.appendingPathComponent(name)
        try await Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
        guard let currentIndex = entries.firstIndex(where: { $0.id == entry.id }) else {
            try? fileManager.removeItem(at: destination)
            throw ClipboardHistoryStoreError.invalidSavedRecord
        }
        var updated = entries[currentIndex]
        let oldCopy = savedCopyURL(for: updated)
        updated.fileCopyName = name
        do { try requiredDatabase().upsert(updated) }
        catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        entries[currentIndex] = updated
        if let oldCopy, oldCopy != destination { try? fileManager.removeItem(at: oldCopy) }
        let thumbnail = thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png")
        try? fileManager.removeItem(at: thumbnail)
        _ = try pruneEntries()
    }

    @discardableResult func applyStoragePolicy() throws -> Bool { try pruneEntries() }

    func delete(_ entry: ClipboardEntry) throws {
        guard let current = entries.first(where: { $0.id == entry.id }) else { return }
        let database = try requiredDatabase()
        var changedGroups: [ClipboardEntry] = []
        var dissolvedIDs: Set<UUID> = []
        if current.kind != .group {
            for group in entries where group.kind == .group && group.groupMemberIDs.contains(current.id) {
                var updated = group
                updated.groupMemberIDs.removeAll { $0 == current.id }
                if updated.groupMemberIDs.count < 2 {
                    dissolvedIDs.insert(group.id)
                } else {
                    changedGroups.append(updated)
                }
            }
        }
        try database.transaction {
            for group in changedGroups { try database.upsert(group) }
            for id in dissolvedIDs { try database.delete(id) }
            try database.delete(current.id)
        }
        entries.removeAll { $0.id == current.id || dissolvedIDs.contains($0.id) }
        for group in changedGroups {
            if let index = entries.firstIndex(where: { $0.id == group.id }) {
                entries[index] = group
            }
        }
        try removePayload(for: current)
    }

    func clear() throws {
        let removed = entries
        try requiredDatabase().deleteAll()
        entries.removeAll()
        for entry in removed { try removePayload(for: entry) }
    }

    /// Record a successful reuse of a saved entry. The app marks its own
    /// pasteboard writes as handled, so the regular clipboard poll will not
    /// refresh this entry for us.
    func recordCopy(of id: UUID) throws -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        var entry = entries[index]
        entry.createdAt = max(now(), (entries.first?.createdAt ?? .distantPast).addingTimeInterval(0.001))
        // Legacy entries have no trustworthy historical total. Start counting
        // their known reuses without inventing an original copy date.
        entry.copyCount = (entry.copyCount ?? 0) + 1
        try requiredDatabase().upsert(entry)
        entries.remove(at: index)
        entries.insert(entry, at: 0)
        return true
    }

    func removeMigrationBackup() throws {
        if fileManager.fileExists(atPath: migrationBackupURL.path) {
            try fileManager.removeItem(at: migrationBackupURL)
        }
    }

    func removeRecoveryFiles() throws {
        if fileManager.fileExists(atPath: recoveryDirectory.path) {
            try fileManager.removeItem(at: recoveryDirectory)
        }
    }

    private func requiredDatabase() throws -> ClipboardHistoryDatabase {
        guard let database else { throw ClipboardHistoryStoreError.unavailable }
        if fileManager.fileExists(atPath: legacyIndexURL.path) {
            throw ClipboardHistoryStoreError.legacyWriterDetected
        }
        return database
    }

    private func refreshExisting(digest: String, sourceAppName: String?, sourceAppBundleID: String?) throws -> Bool {
        guard let index = entries.firstIndex(where: { $0.digest == digest }) else { return false }
        var entry = entries[index]
        entry.createdAt = now()
        if let copyCount = entry.copyCount {
            entry.copyCount = copyCount + 1
        }
        entry.sourceAppName = sourceAppName
        entry.sourceAppBundleID = sourceAppBundleID
        try requiredDatabase().upsert(entry)
        entries.remove(at: index)
        insertNewestFirst(entry)
        return true
    }

    private func insertNewestFirst(_ entry: ClipboardEntry) {
        lastInsertedID = entry.id
        let index = entries.firstIndex { $0.createdAt <= entry.createdAt } ?? entries.endIndex
        entries.insert(entry, at: index)
    }

    private func pruneEntries() throws -> Bool {
        _ = try requiredDatabase()
        if batchInProgress { return false }
        let policy = HistoryStoragePolicy(defaults: defaults)
        var changed = false
        if let cutoff = policy.cutoff(before: now(), calendar: calendar) {
            while let oldest = rootEntries.last, oldest.createdAt < cutoff {
                try delete(oldest)
                changed = true
            }
        }
        if let maxBytes = policy.maximumBytes {
            if activeStorageBytes > Int64(maxBytes) { try moveUnreferencedPayloadsToRecovery() }
            while activeStorageBytes > Int64(maxBytes), let oldest = rootEntries.last {
                try delete(oldest)
                changed = true
            }
        }
        return changed
    }

    private func textURL(for id: UUID) -> URL {
        contentDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    private func savedCopyURL(for entry: ClipboardEntry) -> URL? {
        guard let name = entry.fileCopyName, safeFileName(name) else { return nil }
        let url = fileCopiesDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            .appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) && fileManager.isReadableFile(atPath: url.path)
            ? url : nil
    }

    private func resolvedOriginalURL(for entry: ClipboardEntry) -> URL? {
        if let name = entry.fileBookmarkName, safeFileName(name),
           let data = try? Data(contentsOf: bookmarksDirectory.appendingPathComponent(name)) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ), url.isFileURL { return url }
            if let url = try? URL(
                resolvingBookmarkData: data, options: [],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ), url.isFileURL { return url }
        }
        guard let path = entry.filePath, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func makeFileBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ) { return scoped }
        return try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
    }

    private func removePayload(for entry: ClipboardEntry) throws {
        if entry.kind == .image {
            if let url = imageURL(for: entry) { try fileManager.removeItem(at: url) }
        } else if entry.kind != .unavailableImage
                    && entry.kind != .fileReference && entry.kind != .group {
            let url = textURL(for: entry.id)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        for name in [entry.rtfFileName, entry.htmlFileName, entry.rtfdFileName] {
            guard let name, safeFileName(name) else { continue }
            let url = richTextDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        if let name = entry.fileBookmarkName, safeFileName(name) {
            let url = bookmarksDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        let copyFolder = fileCopiesDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: copyFolder.path) { try fileManager.removeItem(at: copyFolder) }
        let thumbnail = thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png")
        if fileManager.fileExists(atPath: thumbnail.path) { try fileManager.removeItem(at: thumbnail) }
    }

    private func moveUnreferencedPayloadsToRecovery() throws {
        let textNames = Set(entries.filter { $0.kind != .image && $0.kind != .unavailableImage
            && $0.kind != .fileReference && $0.kind != .group }
            .map { "\($0.id.uuidString).txt" })
        let imageNames = Set(entries.compactMap(\.imageFileName))
        let richNames = Set(entries.flatMap { [$0.rtfFileName, $0.htmlFileName, $0.rtfdFileName].compactMap { $0 } })
        let bookmarkNames = Set(entries.compactMap(\.fileBookmarkName))
        let thumbnailNames = Set(entries.filter { $0.kind == .fileReference }.map { "\($0.id.uuidString).png" })
        let copyFolderNames = Set(entries.filter { $0.fileCopyName != nil }.map { $0.id.uuidString })
        for (folder, names) in [
            (contentDirectory, textNames), (imagesDirectory, imageNames),
            (richTextDirectory, richNames), (bookmarksDirectory, bookmarkNames),
            (thumbnailsDirectory, thumbnailNames), (fileCopiesDirectory, copyFolderNames)
        ] {
            for url in try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where !names.contains(url.lastPathComponent) {
                try moveToRecovery(url, in: folder.lastPathComponent)
            }
        }
        for entry in entries where entry.kind == .fileReference && entry.fileCopyName != nil {
            let folder = fileCopiesDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            guard fileManager.fileExists(atPath: folder.path) else { continue }
            for url in try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.lastPathComponent != entry.fileCopyName {
                try moveToRecovery(url, in: "FileCopies/\(entry.id.uuidString)")
            }
        }
    }

    private func moveToRecovery(_ url: URL, in relativeFolder: String) throws {
        let destinationFolder = recoveryDirectory.appendingPathComponent(relativeFolder, isDirectory: true)
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        var destination = destinationFolder.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            destination = destinationFolder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        }
        try fileManager.moveItem(at: url, to: destination)
    }

    private func migrateLegacyHistory() throws {
        let legacyData = try Data(contentsOf: legacyIndexURL)
        let legacy = try JSONDecoder().decode([LegacyClipboardEntry].self, from: legacyData)
        let current = legacy.compactMap(\.current)
        guard current.count == legacy.count,
              Set(current.map(\.id)).count == current.count,
              Set(current.map(\.digest)).count == current.count else {
            throw ClipboardHistoryStoreError.invalidLegacyRecord
        }
        for entry in current {
            if entry.kind == .image {
                guard let name = entry.imageFileName, safeFileName(name),
                      fileManager.fileExists(atPath: imagesDirectory.appendingPathComponent(name).path) else {
                    throw ClipboardHistoryStoreError.invalidLegacyRecord
                }
            } else if entry.text == nil {
                throw ClipboardHistoryStoreError.invalidLegacyRecord
            }
        }

        // Copy the JSON and every referenced image before changing the index.
        if fileManager.fileExists(atPath: migrationBackupURL.path) {
            let backupData = try Data(contentsOf: migrationBackupURL.appendingPathComponent("history.json"))
            guard backupData == legacyData else { throw ClipboardHistoryStoreError.invalidLegacyRecord }
        } else {
            let staging = directory.appendingPathComponent("LegacyMigrationBackup.pending", isDirectory: true)
            if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                try fileManager.copyItem(at: legacyIndexURL, to: staging.appendingPathComponent("history.json"))
                let backupImages = staging.appendingPathComponent("Images", isDirectory: true)
                try fileManager.createDirectory(at: backupImages, withIntermediateDirectories: true)
                for name in Set(current.compactMap(\.imageFileName)) {
                    try fileManager.copyItem(
                        at: imagesDirectory.appendingPathComponent(name),
                        to: backupImages.appendingPathComponent(name)
                    )
                }
                try fileManager.moveItem(at: staging, to: migrationBackupURL)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }

        let temporary = directory.appendingPathComponent("history.sqlite.migrating")
        if fileManager.fileExists(atPath: temporary.path) { try fileManager.removeItem(at: temporary) }
        let migrated = try ClipboardHistoryDatabase(url: temporary)
        do {
            for entry in current where entry.kind != .image {
                try Data((entry.text ?? "").utf8).write(to: textURL(for: entry.id), options: .atomic)
            }
            try migrated.transaction {
                for entry in current { try migrated.upsert(entry) }
            }
            let checked = try migrated.entries(contentDirectory: contentDirectory)
            guard checked.count == current.count,
                  Set(checked.map(\.id)) == Set(current.map(\.id)),
                  checked.allSatisfy({ entry in
                      entry.kind == .image || entry.text == current.first(where: { $0.id == entry.id })?.text
                  }) else {
                throw ClipboardHistoryStoreError.migrationVerificationFailed
            }
            migrated.close()
            try fileManager.moveItem(at: temporary, to: databaseURL)
            try fileManager.removeItem(at: legacyIndexURL)
        } catch {
            migrated.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func safeFileName(_ name: String) -> Bool {
        !name.isEmpty && name == URL(fileURLWithPath: name).lastPathComponent && !name.contains("..")
    }

    private func diskBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private func diskBytes(in folder: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    private static func digest(data: Data, prefix: String) -> String {
        let hash = SHA256.hash(data: Data(prefix.utf8) + data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func imageExtension(for type: String) -> String {
        switch type {
        case "public.png": "png"
        case "public.jpeg": "jpg"
        case "public.heic": "heic"
        case "public.heif": "heif"
        case "com.compuserve.gif": "gif"
        case "public.tiff": "tiff"
        default: "tiff"
        }
    }

    private static func isWebLink(_ value: String) -> Bool {
        ClipboardEntry.webURL(from: value) != nil
    }
}
