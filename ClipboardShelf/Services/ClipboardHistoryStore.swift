import CryptoKit
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import AppKit
import os

/// Keeps a security-scoped original accessible while Quick Look renders it.
/// A saved copy lives in our own storage and needs no security scope.
final class FilePreviewAccess {
    let url: URL
    private let securityScopeURL: URL?

    init?(
        url: URL, usesSecurityScope: Bool, requireReadable: Bool = true,
        containingFolderScope: URL? = nil
    ) {
        let requestedScope = containingFolderScope ?? (usesSecurityScope ? url : nil)
        let started = requestedScope?.startAccessingSecurityScopedResource() == true
        guard (try? url.checkResourceIsReachable()) == true,
              (!requireReadable || FileManager.default.isReadableFile(atPath: url.path)) else {
            if started { requestedScope?.stopAccessingSecurityScopedResource() }
            return nil
        }
        self.url = url
        securityScopeURL = started ? requestedScope : nil
    }

    deinit {
        securityScopeURL?.stopAccessingSecurityScopedResource()
    }

    func bookmarkForTransfer() -> (data: Data, isFolder: Bool)? {
        let scope = securityScopeURL ?? url
        let options: URL.BookmarkCreationOptions = securityScopeURL == nil ? .minimalBookmark
            : [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        guard let data = (try? scope.bookmarkData(options: options,
                                                includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? scope.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)) else {
            return nil
        }
        return (data, scope.standardizedFileURL != url.standardizedFileURL)
    }
}

enum ClipboardHistoryStoreError: LocalizedError {
    case unavailable, invalidLegacyRecord, migrationVerificationFailed, legacyWriterDetected, invalidSavedRecord
    case fileReferenceUnavailable, fileCopyExceedsLimit, unsupportedFile
    case invalidBatch, ocrSourceChanged, ocrResultTooLarge
    case textEditUnavailable, textEditConflict, textEditEmpty, textEditTooLarge, textEditExceedsLimit
    case favoriteCategoryEmpty, favoriteCategoryNameTaken, favoriteCategoryMissing, historyEntryMissing

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
        case .ocrSourceChanged: "图片在识别过程中发生变化，请重新识别。"
        case .ocrResultTooLarge: "识别出的文字过长，无法保存。"
        case .textEditUnavailable: "这张卡片的文字已不可用。"
        case .textEditConflict: "卡片内容已更新，请重新打开编辑器。"
        case .textEditEmpty: "请输入要保存的文字。"
        case .textEditTooLarge: "文字超过 32 MB，请缩短后重试。"
        case .textEditExceedsLimit: "这次编辑会超出历史存储上限。请缩短文字或在设置中调整上限。"
        case .favoriteCategoryEmpty: "请输入收藏分类名称。"
        case .favoriteCategoryNameTaken: "这个名称已被使用，请换一个名称。"
        case .favoriteCategoryMissing: "这个收藏分类已不存在。"
        case .historyEntryMissing: "有卡片已不在历史中。请关闭后重新选择。"
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

private struct ImageOCRCacheRecord: Codable {
    let sourceSignature: String
    let text: String
}

private struct ScreenshotEditRecord: Codable {
    let version: Int
    let base: Data
    let document: Data
}

private struct HistoryPayloadUsage {
    var totalBytes: Int64 = 0
    var bytesByPath: [String: Int64] = [:]

    mutating func remove(_ urls: [URL]) {
        for url in urls {
            totalBytes -= bytesByPath.removeValue(forKey: url.path) ?? 0
        }
    }
}

@MainActor
final class ClipboardHistoryStore {
    private let fileManager = FileManager.default
    private let directory: URL
    private let imagesDirectory: URL
    private let screenshotBasesDirectory: URL
    private let screenshotAnnotationsDirectory: URL
    private let contentDirectory: URL
    private let richTextDirectory: URL
    private let bookmarksDirectory: URL
    private let fileCopiesDirectory: URL
    private let thumbnailsDirectory: URL
    private let ocrDirectory: URL
    private let databaseURL: URL
    private let legacyIndexURL: URL
    private let migrationBackupURL: URL
    private let recoveryDirectory: URL
    private let weChatFolderBookmarksURL: URL
    private var weChatFolderBookmarks: [Data]
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar
    private var database: ClipboardHistoryDatabase?
    private var blockedByLegacyIndex = false
    /// A file URL read from another app's pasteboard may carry access that a
    /// serialized bookmark cannot reproduce. Retain that original URL and its
    /// security scope for this process, without retaining the file's bytes.
    private var liveOriginalFileAccesses: [UUID: FilePreviewAccess] = [:]
    private let fileAccessLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ClipHoook", category: "FileAccess"
    )
    private var batchInProgress = false
    private var lastInsertedID: UUID?
    /// Captured before the store creates its support directory. Existing users
    /// should discover new features in the shelf without a first-run popup.
    let isNewInstallation: Bool
    var stagingShelfDirectory: URL { directory.appendingPathComponent("StagingShelf", isDirectory: true) }

    private(set) var entries: [ClipboardEntry] = []
    private(set) var favoriteCategories: [ClipboardFavoriteCategory] = []
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
            if entry.shelfPinOrder == nil,
               let groupedAt = lastGroupedAt[entry.id], entry.createdAt <= groupedAt {
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
        screenshotBasesDirectory = directory.appendingPathComponent("ScreenshotBases", isDirectory: true)
        screenshotAnnotationsDirectory = directory.appendingPathComponent("ScreenshotAnnotations", isDirectory: true)
        contentDirectory = directory.appendingPathComponent("Content", isDirectory: true)
        richTextDirectory = directory.appendingPathComponent("RichText", isDirectory: true)
        bookmarksDirectory = directory.appendingPathComponent("Bookmarks", isDirectory: true)
        fileCopiesDirectory = directory.appendingPathComponent("FileCopies", isDirectory: true)
        thumbnailsDirectory = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        ocrDirectory = directory.appendingPathComponent("OCR", isDirectory: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        legacyIndexURL = directory.appendingPathComponent("history.json")
        migrationBackupURL = directory.appendingPathComponent("LegacyMigrationBackup", isDirectory: true)
        recoveryDirectory = directory.appendingPathComponent("UnreferencedRecovery", isDirectory: true)
        weChatFolderBookmarksURL = directory.appendingPathComponent("WeChatFolderBookmarks.plist")
        weChatFolderBookmarks = (try? PropertyListDecoder().decode(
            [Data].self, from: Data(contentsOf: weChatFolderBookmarksURL)
        )) ?? []
        var loadedDatabase = false
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: screenshotBasesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: screenshotAnnotationsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: richTextDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: bookmarksDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: fileCopiesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: ocrDirectory, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: databaseURL.path),
               fileManager.fileExists(atPath: legacyIndexURL.path) {
                try migrateLegacyHistory()
            }
            let openedDatabase = try ClipboardHistoryDatabase(url: databaseURL)
            database = openedDatabase
            entries = try openedDatabase.entries(contentDirectory: contentDirectory)
            loadedDatabase = true
            favoriteCategories = try openedDatabase.favoriteCategories()
            loadOCRResults()
            if fileManager.fileExists(atPath: legacyIndexURL.path) {
                throw ClipboardHistoryStoreError.legacyWriterDetected
            }
            try restoreScreenshotOrigins()
            try moveUnreferencedPayloadsToRecovery()
            _ = try pruneEntries()
        } catch {
            database = nil
            if case ClipboardHistoryStoreError.legacyWriterDetected = error {
                blockedByLegacyIndex = true
            }
            // A downgraded build can recreate a small JSON index beside the
            // complete SQLite history. Preserve the latter for read-only
            // display; never replace it with the downgraded build's subset.
            if !loadedDatabase,
               let data = try? Data(contentsOf: legacyIndexURL),
               let legacy = try? JSONDecoder().decode([LegacyClipboardEntry].self, from: data) {
                entries = legacy.compactMap(\.current).sorted { $0.createdAt > $1.createdAt }
            }
            errorMessage = "无法读取历史记录：\(error.localizedDescription)"
        }
    }

    var activeStorageBytes: Int64 {
        diskBytes(at: databaseURL) + payloadDirectories.reduce(0) { $0 + diskBytes(in: $1) }
    }

    private var payloadDirectories: [URL] {
        [contentDirectory, imagesDirectory, screenshotBasesDirectory, screenshotAnnotationsDirectory,
         richTextDirectory, bookmarksDirectory, fileCopiesDirectory, thumbnailsDirectory, ocrDirectory]
    }

    var migrationBackupBytes: Int64 { diskBytes(in: migrationBackupURL) }
    var recoveryBytes: Int64 { diskBytes(in: recoveryDirectory) }
    var pinnedImagesDirectory: URL { directory.appendingPathComponent("PinnedImages", isDirectory: true) }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let name = entry.imageFileName, safeFileName(name) else { return nil }
        let url = imagesDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Editable screenshot data is kept beside the flattened card image. Old
    /// cards have no sidecar and can still receive new annotations.
    func screenshotEditData(for entry: ClipboardEntry) -> (base: Data, document: Data)? {
        guard entry.kind == .image else { return nil }
        let recordURL = screenshotEditURL(for: entry.id)
        if fileManager.fileExists(atPath: recordURL.path) {
            guard let data = try? Data(contentsOf: recordURL),
                  let record = try? PropertyListDecoder().decode(ScreenshotEditRecord.self, from: data),
                  record.version == 1, !record.base.isEmpty, !record.document.isEmpty else { return nil }
            return (record.base, record.document)
        }
        // Read existing two-file records without rewriting them on launch.
        let name = entry.id.uuidString
        let baseURL = screenshotBasesDirectory.appendingPathComponent("\(name).image")
        let documentURL = screenshotAnnotationsDirectory.appendingPathComponent("\(name).json")
        guard let base = try? Data(contentsOf: baseURL),
              let document = try? Data(contentsOf: documentURL) else { return nil }
        return (base, document)
    }

    func saveScreenshotEditData(base: Data, document: Data,
                                for entry: ClipboardEntry) throws {
        guard entry.kind == .image, !base.isEmpty, !document.isEmpty,
              entries.contains(where: { $0.id == entry.id }) else {
            throw ClipboardHistoryStoreError.invalidSavedRecord
        }
        _ = try requiredDatabase()
        // One atomic replacement commits the matching base/document pair.
        // A write failure or interruption leaves the last editable version intact.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(ScreenshotEditRecord(version: 1, base: base, document: document))
        try data.write(to: screenshotEditURL(for: entry.id), options: .atomic)
        // Remove legacy files only after the new pair has been committed.
        let name = entry.id.uuidString
        try? fileManager.removeItem(at: screenshotBasesDirectory.appendingPathComponent("\(name).image"))
        try? fileManager.removeItem(at: screenshotAnnotationsDirectory.appendingPathComponent("\(name).json"))
        _ = try pruneEntries()
    }

    private func screenshotEditURL(for id: UUID) -> URL {
        screenshotAnnotationsDirectory.appendingPathComponent("\(id.uuidString).plist")
    }

    func ocrSourceSignature(for entry: ClipboardEntry) -> String? {
        guard entry.isImagePreviewable else { return nil }
        if entry.kind == .image {
            return imageURL(for: entry) == nil ? nil : entry.digest
        }
        return withUsableFileURL(for: entry) { url in
            guard let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey
            ]) else { return nil }
            let modified = values.contentModificationDate.map {
                Int64(($0.timeIntervalSince1970 * 1_000).rounded())
            } ?? -1
            return "\(entry.digest)|\(entry.fileCopyName ?? "")|\(url.standardizedFileURL.path)|\(values.fileSize ?? -1)|\(modified)"
        } ?? nil
    }

    func saveOCRText(_ text: String, for entry: ClipboardEntry,
                     expectedSourceSignature: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }),
              ocrSourceSignature(for: entries[index]) == expectedSourceSignature else {
            throw ClipboardHistoryStoreError.ocrSourceChanged
        }
        guard text.utf8.count <= 2 * 1_024 * 1_024 else {
            throw ClipboardHistoryStoreError.ocrResultTooLarge
        }
        let record = ImageOCRCacheRecord(sourceSignature: expectedSourceSignature, text: text)
        try JSONEncoder().encode(record).write(to: ocrURL(for: entry.id), options: .atomic)
        entries[index].ocrText = text
    }

    private func loadOCRResults() {
        for index in entries.indices where entries[index].isImagePreviewable {
            let entry = entries[index]
            guard let data = try? Data(contentsOf: ocrURL(for: entry.id)),
                  let record = try? JSONDecoder().decode(ImageOCRCacheRecord.self, from: data),
                  record.sourceSignature == ocrSourceSignature(for: entry) else { continue }
            entries[index].ocrText = record.text
        }
    }

    /// Upgrade only records with positive provenance. Do not change their
    /// copy dates, counts, source labels or payloads, or overwrite a correction.
    private func restoreScreenshotOrigins() throws {
        var updates: [(Int, ClipboardEntry)] = []
        for index in entries.indices {
            let entry = entries[index]
            guard entry.screenshotOrigin == nil,
                  entry.isImagePreviewable || entry.kind == .unavailableImage else { continue }
            var origin = entry.resolvedScreenshotOrigin
            if origin == nil && entry.kind == .fileReference {
                origin = withUsableFileURL(for: entry) {
                    ClipboardScreenshotMetadata.origin(in: nil, fileURL: $0)
                } ?? nil
            }
            guard let origin else { continue }
            var updated = entry
            updated.screenshotOrigin = origin
            updates.append((index, updated))
        }
        guard !updates.isEmpty else { return }
        let database = try requiredDatabase()
        var restoredIDs: Set<UUID> = []
        try database.transaction {
            for (_, entry) in updates {
                if let origin = entry.screenshotOrigin,
                   try database.updateScreenshotOrigin(origin, for: entry.id, onlyIfUnset: true) {
                    restoredIDs.insert(entry.id)
                }
            }
        }
        for (index, entry) in updates where restoredIDs.contains(entry.id) { entries[index] = entry }
    }

    private func ocrURL(for id: UUID) -> URL {
        ocrDirectory.appendingPathComponent("\(id.uuidString).json")
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
        return originalFileAccess(for: entry)
    }

    /// Re-publish a file only while its source or explicit saved copy is
    /// currently readable. WeChat's temporary files can remain accessible
    /// after its pasteboard item changes; their location alone is not a reason
    /// to force a relink. Once WeChat removes the file, FilePreviewAccess fails
    /// and copy/drag falls back to recovery without publishing a dead URL.
    func filePasteboardAccess(for entry: ClipboardEntry) -> FilePreviewAccess? {
        guard entry.kind == .fileReference else { return nil }
        if let copy = savedCopyURL(for: entry) {
            return FilePreviewAccess(url: copy, usesSecurityScope: false)
        }
        if let access = originalFileAccess(for: entry) { return access }
        if ClipboardImageCapture.isWeChatSource(
            name: entry.sourceAppName, bundleID: entry.sourceAppBundleID
        ) {
            fileAccessLogger.error(
                "WeChat file unavailable: live=false bookmark=\(entry.fileBookmarkName != nil)"
            )
        }
        return nil
    }

    func originalFileIsAvailable(_ entry: ClipboardEntry) -> Bool {
        withOriginalFileURL(for: entry) { _ in true } ?? false
    }

    func originalFileCanBeReused(_ entry: ClipboardEntry) -> Bool {
        originalFileIsAvailable(entry)
    }

    func withOriginalFileURL<T>(for entry: ClipboardEntry, _ work: (URL) -> T) -> T? {
        guard entry.kind == .fileReference else { return nil }
        guard let access = originalFileAccess(for: entry) else { return nil }
        return work(access.url)
    }

    func withUsableFileURL<T>(for entry: ClipboardEntry, _ work: (URL) -> T) -> T? {
        guard entry.kind == .fileReference else { return nil }
        if let copy = savedCopyURL(for: entry) { return work(copy) }
        return withOriginalFileURL(for: entry, work)
    }

    private func liveOriginalAccess(for entry: ClipboardEntry) -> FilePreviewAccess? {
        guard let access = liveOriginalFileAccesses[entry.id] else { return nil }
        guard access.url.standardizedFileURL.path == entry.filePath,
              (try? access.url.checkResourceIsReachable()) == true,
              fileManager.isReadableFile(atPath: access.url.path) else {
            liveOriginalFileAccesses.removeValue(forKey: entry.id)
            return nil
        }
        return access
    }

    private func originalFileAccess(for entry: ClipboardEntry) -> FilePreviewAccess? {
        if let live = liveOriginalAccess(for: entry) { return live }
        if let url = resolvedOriginalURL(for: entry),
           let access = FilePreviewAccess(url: url, usesSecurityScope: true) {
            return access
        }
        if let access = authorizedWeChatFolderAccess(for: entry) { return access }
        // A previously relinked card may share an exact destination path with
        // a Finder card that already has a working bookmark. Reuse that grant
        // only for the identical path; a matching name or size is insufficient.
        guard let path = entry.filePath else { return nil }
        for other in entries where other.id != entry.id && other.kind == .fileReference
            && other.filePath == path {
            if let live = liveOriginalAccess(for: other) { return live }
            if let url = resolvedOriginalURL(for: other),
               let access = FilePreviewAccess(url: url, usesSecurityScope: true) {
                return access
            }
        }
        return nil
    }

    /// Grant only the stable WeChat folder that contains this card's source.
    /// An open-panel selection is required; a path learned from the clipboard
    /// alone is not treated as permission. No file bytes are copied or scanned.
    func suggestedWeChatFolder(for entry: ClipboardEntry) -> URL? {
        guard entry.kind == .fileReference,
              ClipboardImageCapture.isWeChatSource(
                name: entry.sourceAppName, bundleID: entry.sourceAppBundleID
              ), let path = entry.filePath else { return nil }
        let roots = [
            "/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/",
            "/Library/Containers/com.tencent.xinWeChat/Data/temp/RWTemp/"
        ]
        for root in roots {
            guard let range = path.range(of: root) else { continue }
            let folderPath = String(path[..<range.upperBound].dropLast())
            return URL(fileURLWithPath: folderPath, isDirectory: true)
        }
        return nil
    }

    func authorizeWeChatFolder(_ selected: URL, for entry: ClipboardEntry) throws {
        guard let expected = suggestedWeChatFolder(for: entry),
              selected.standardizedFileURL.path == expected.standardizedFileURL.path,
              let path = entry.filePath else {
            throw ClipboardHistoryStoreError.fileReferenceUnavailable
        }
        let fileURL = URL(fileURLWithPath: path)
        guard FilePreviewAccess(url: fileURL, usesSecurityScope: false,
                                containingFolderScope: selected) != nil,
              let bookmark = makeFileBookmark(for: selected) else {
            throw ClipboardHistoryStoreError.fileReferenceUnavailable
        }
        let selectedPath = selected.standardizedFileURL.path
        let remaining = weChatFolderBookmarks.filter { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
            return url.standardizedFileURL.path != selectedPath
        }
        let updated = remaining + [bookmark]
        let encoded = try PropertyListEncoder().encode(updated)
        try encoded.write(to: weChatFolderBookmarksURL, options: .atomic)
        weChatFolderBookmarks = updated
    }

    private func authorizedWeChatFolderAccess(for entry: ClipboardEntry) -> FilePreviewAccess? {
        guard let path = entry.filePath,
              suggestedWeChatFolder(for: entry) != nil else { return nil }
        for data in weChatFolderBookmarks {
            var stale = false
            guard let folder = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                        relativeTo: nil, bookmarkDataIsStale: &stale),
                  !stale,
                  path.hasPrefix(folder.standardizedFileURL.path + "/") else { continue }
            if let access = FilePreviewAccess(url: URL(fileURLWithPath: path),
                                              usesSecurityScope: false,
                                              containingFolderScope: folder) {
                return access
            }
        }
        return nil
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
           !fileManager.fileExists(atPath: textURL(for: old).path) {
            try data.write(to: textURL(for: old), options: .atomic)
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
        let url = textURL(for: entry)
        try data.write(to: url, options: .atomic)
        do { try requiredDatabase().upsert(entry) }
        catch { try? fileManager.removeItem(at: url); throw error }
        insertNewestFirst(entry)
        _ = try pruneEntries()
        return true
    }

    /// Edits the recorded content in place without recording a copy event.
    func editText(_ text: String, original: ClipboardEntry) throws -> ClipboardEntry? {
        guard let index = entries.firstIndex(where: { $0.id == original.id }),
              entries[index].kind.isTextual, let previousText = entries[index].text else {
            throw ClipboardHistoryStoreError.textEditUnavailable
        }
        let previous = entries[index]
        guard previous.digest == original.digest, previous.textRevision == original.textRevision else {
            throw ClipboardHistoryStoreError.textEditConflict
        }
        guard !text.utf8.elementsEqual(previousText.utf8) else { return nil }
        guard !text.isEmpty else { throw ClipboardHistoryStoreError.textEditEmpty }
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else { throw ClipboardHistoryStoreError.textEditTooLarge }

        var updated = previous
        updated.text = text
        updated.kind = Self.isWebLink(text) ? .link : .text
        updated.textRevision = UUID()
        updated.byteCount = data.count
        updated.rtfFileName = nil
        updated.htmlFileName = nil
        updated.rtfdFileName = nil
        let canonicalDigest = Self.digest(data: data, prefix: updated.kind.rawValue)
        let matchesAnotherEntry = entries.contains { $0.id != updated.id && $0.digest == canonicalDigest }
        updated.digest = matchesAnotherEntry
            ? Self.digest(data: data, prefix: "edited-\(updated.id.uuidString)") : canonicalDigest

        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        byID[updated.id] = updated
        let groupIndexes = entries.indices.filter { entries[$0].groupMemberIDs.contains(updated.id) }
        let groups = groupIndexes.map { refreshedGroup(entries[$0], memberIDs: entries[$0].groupMemberIDs, byID: byID) }
        let previousFiles = [textURL(for: previous)] + richTextURLs(for: previous)
        let staged = textURL(for: updated)
        let database = try requiredDatabase()
        do {
            // The index commits the new payload name and all affected groups together.
            // Until that commit, the old payload remains readable at its original path.
            try database.transaction {
                try data.write(to: staged, options: .atomic)
                if let maximum = HistoryStoragePolicy(defaults: defaults).maximumBytes {
                    let replacedBytes = previousFiles.reduce(0) { $0 + diskBytes(at: $1) }
                    if diskBytes(at: staged) > replacedBytes, activeStorageBytes - replacedBytes > Int64(maximum) {
                        throw ClipboardHistoryStoreError.textEditExceedsLimit
                    }
                }
                try database.upsert(updated)
                for group in groups { try database.upsert(group) }
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        entries[index] = updated
        for (groupIndex, group) in zip(groupIndexes, groups) { entries[groupIndex] = group }
        for url in previousFiles { try? fileManager.removeItem(at: url) }
        return updated
    }

    func addImage(
        _ data: Data, type: String, sourceAppName: String?, sourceAppBundleID: String? = nil,
        occurrence: Int = 0, screenshotOrigin: ClipboardScreenshotOrigin? = nil
    ) throws -> Bool {
        guard !data.isEmpty, data.count <= maximumImageBytes else { return false }
        _ = try requiredDatabase()
        let origin = screenshotOrigin ?? ClipboardScreenshotOrigin.knownSource(
            name: sourceAppName, bundleID: sourceAppBundleID)
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
        if try refreshExisting(digest: digest, sourceAppName: sourceAppName,
                               sourceAppBundleID: sourceAppBundleID, screenshotOrigin: origin) {
            _ = try pruneEntries()
            return true
        }
        let id = UUID()
        let name = "\(id.uuidString).\(Self.imageExtension(for: type))"
        let url = imagesDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let date = now()
        var entry = ClipboardEntry(
            id: id, createdAt: date, firstCopiedAt: date, copyCount: 1,
            kind: .image, text: nil, imageFileName: name, imagePasteboardType: type,
            digest: digest, byteCount: data.count, sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
        entry.screenshotOrigin = origin
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
            updated.recordedAt = existing.calendarRecordTimes + [now()]
            updated.createdAt = max(now(), (entries.first?.createdAt ?? .distantPast).addingTimeInterval(0.001))
            updated.sourceAppName = "iPhone 截图"
            updated.sourceAppBundleID = nil
            updated.screenshotOrigin = .phone
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
        var entry = ClipboardEntry(
            id: id, createdAt: receivedAt, firstCopiedAt: nil, copyCount: nil,
            kind: .image, text: nil, imageFileName: name, imagePasteboardType: type,
            digest: digest, byteCount: data.count, sourceAppName: "iPhone 截图",
            sourceAppBundleID: nil
        )
        entry.screenshotOrigin = .phone
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
            let oldText = textURL(for: old)
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
        let files: [(URL, Data)] = [(textURL(for: entry), textData)] +
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
        occurrence: Int = 0, screenshotOrigin: ClipboardScreenshotOrigin? = nil,
        screenRecording: ClipboardRecordingMetadata? = nil
    ) throws -> Bool {
        guard fileURL.isFileURL else { return false }
        _ = try requiredDatabase()
        let startedScope = fileURL.startAccessingSecurityScopedResource()
        defer { if startedScope { fileURL.stopAccessingSecurityScopedResource() } }
        let liveAccess = FilePreviewAccess(url: fileURL, usesSecurityScope: true)
        let normalized = fileURL.standardizedFileURL
        let origin = screenshotOrigin ?? ClipboardScreenshotOrigin.knownSource(
            name: sourceAppName, bundleID: sourceAppBundleID)
            ?? ClipboardScreenshotMetadata.origin(in: nil, fileURL: fileURL)
        let digest = Self.digest(data: Data(normalized.path.utf8),
                                 prefix: Self.batchPrefix("file-reference", occurrence: occurrence))
        let bookmark = makeFileBookmark(for: fileURL)
        if liveAccess == nil && ClipboardImageCapture.isWeChatSource(
            name: sourceAppName, bundleID: sourceAppBundleID
        ) {
            fileAccessLogger.error("WeChat capture has no live file access; bookmark=\(bookmark != nil)")
        }
        // Older builds changed filePath during relink but kept the original
        // digest. A later copy of the old WeChat path then refreshed that
        // relinked card and replaced its good bookmark with the old location.
        // Detach the mismatched record before deduplicating this capture.
        if let index = entries.firstIndex(where: {
            $0.digest == digest && $0.kind == .fileReference && $0.filePath != normalized.path
        }) {
            var relinked = entries[index]
            relinked.digest = Self.relinkedFileDigest(for: relinked.id)
            try requiredDatabase().upsert(relinked)
            entries[index] = relinked
        }
        if try refreshExisting(digest: digest, sourceAppName: sourceAppName,
                               sourceAppBundleID: sourceAppBundleID, screenshotOrigin: origin) {
            // Re-copying a file can supply a fresh pasteboard security scope.
            // Replace a stale bookmark instead of retaining the old one.
            if let bookmark, let index = entries.firstIndex(where: { $0.digest == digest }) {
                var refreshed = entries[index]
                let name = refreshed.fileBookmarkName ?? "\(refreshed.id.uuidString).bookmark"
                try bookmark.write(to: bookmarksDirectory.appendingPathComponent(name), options: .atomic)
                if refreshed.fileBookmarkName == nil {
                    refreshed.fileBookmarkName = name
                    try requiredDatabase().upsert(refreshed)
                    entries[index] = refreshed
                }
            }
            if let liveAccess, let refreshed = entries.first(where: { $0.digest == digest }) {
                liveOriginalFileAccesses[refreshed.id] = liveAccess
            }
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
        entry.screenRecording = screenRecording
        if entry.isImagePreviewable { entry.screenshotOrigin = origin }
        if let bookmark {
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
        if let liveAccess { liveOriginalFileAccesses[entry.id] = liveAccess }
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
                    case .image(let data, let type, let origin):
                        added = try addImage(data, type: type, sourceAppName: sourceAppName,
                                             sourceAppBundleID: sourceAppBundleID,
                                             occurrence: occurrence, screenshotOrigin: origin)
                    case .unavailableImage(let url):
                        added = try addUnavailableImageReference(
                            url, sourceAppName: sourceAppName,
                            sourceAppBundleID: sourceAppBundleID,
                            occurrence: occurrence
                        )
                    case .fileReference(let url, let origin):
                        added = try addFileReference(url, sourceAppName: sourceAppName,
                                                      sourceAppBundleID: sourceAppBundleID,
                                                      occurrence: occurrence, screenshotOrigin: origin)
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
            for entry in newEntries {
                liveOriginalFileAccesses.removeValue(forKey: entry.id)
                try? removePayload(for: entry)
            }
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
        case .image(let data, _, _):
            hasher.combine(2)
            hasher.combine(data)
        case .unavailableImage(let url):
            hasher.combine(3)
            hasher.combine(url.standardizedFileURL.path)
        case .fileReference(let url, _):
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

    /// Rearranges existing history records without writing to the system pasteboard.
    /// Members moved out of an older group leave the other members grouped when
    /// at least two remain; otherwise the old group is dissolved.
    func groupSelection(memberIDs: [UUID]) throws -> UUID? {
        var seen: Set<UUID> = []
        let orderedIDs = memberIDs.filter { seen.insert($0).inserted }
        guard orderedIDs.count > 1 else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        guard orderedIDs.allSatisfy({ byID[$0].map { $0.kind != .group } == true }) else {
            throw ClipboardHistoryStoreError.invalidBatch
        }
        let chosenIDs = Set(orderedIDs)
        let database = try requiredDatabase()
        let before = entries
        do {
            var newGroupID: UUID?
            try database.transaction {
                for group in before where group.kind == .group &&
                    group.groupMemberIDs.contains(where: chosenIDs.contains) {
                    let remaining = group.groupMemberIDs.filter { !chosenIDs.contains($0) }
                    if remaining.count < 2 {
                        try database.delete(group.id)
                        entries.removeAll { $0.id == group.id }
                    } else {
                        let updated = refreshedGroup(group, memberIDs: remaining, byID: byID)
                        try database.upsert(updated)
                        if let index = entries.firstIndex(where: { $0.id == group.id }) {
                            entries[index] = updated
                        }
                    }
                }
                newGroupID = try upsertGroup(
                    memberIDs: orderedIDs, sourceAppName: "ClipHoook",
                    sourceAppBundleID: Bundle.main.bundleIdentifier,
                    recordCopy: false
                )
            }
            return newGroupID
        } catch {
            entries = before
            throw error
        }
    }

    /// Removes only group records; their member content remains in history.
    func ungroupSelection(groupIDs: [UUID]) throws -> Bool {
        let ids = Set(groupIDs)
        let groups = entries.filter { ids.contains($0.id) && $0.kind == .group }
        guard !groups.isEmpty else { return false }
        var favoriteGroupsByMember: [UUID: ClipboardEntry] = [:]
        // Groups are newest first. If a member is shared, inherit the newer group's category.
        for group in groups where group.isFavorite {
            for id in group.groupMemberIDs where favoriteGroupsByMember[id] == nil {
                favoriteGroupsByMember[id] = group
            }
        }
        let favoriteMembers = entries.compactMap { entry -> ClipboardEntry? in
            guard !entry.isFavorite, let group = favoriteGroupsByMember[entry.id] else { return nil }
            var updated = entry
            updated.isFavorite = true
            updated.favoriteCategoryID = group.favoriteCategoryID
            return updated
        }
        let database = try requiredDatabase()
        try database.transaction {
            for member in favoriteMembers { try database.upsert(member) }
            for group in groups { try database.delete(group.id) }
        }
        for member in favoriteMembers {
            if let index = entries.firstIndex(where: { $0.id == member.id }) { entries[index] = member }
        }
        entries.removeAll { ids.contains($0.id) && $0.kind == .group }
        return true
    }

    private func refreshedGroup(
        _ group: ClipboardEntry, memberIDs: [UUID], byID: [UUID: ClipboardEntry]
    ) -> ClipboardEntry {
        var updated = group
        updated.groupMemberIDs = memberIDs
        updated.digest = Self.digest(
            data: Data(memberIDs.compactMap { byID[$0]?.digest }.joined(separator: "\n").utf8),
            prefix: "group"
        )
        updated.byteCount = memberIDs.reduce(0) { $0 + (byID[$1]?.byteCount ?? 0) }
        return updated
    }

    private func upsertGroup(
        memberIDs: [UUID], sourceAppName: String?, sourceAppBundleID: String?,
        recordCopy: Bool = true
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
            if recordCopy {
                group.copyCount = (group.copyCount ?? 0) + 1
                group.recordedAt = group.calendarRecordTimes + [now()]
            }
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
        group.recordedAt = recordCopy ? [now()] : []
        try requiredDatabase().upsert(group)
        insertNewestFirst(group)
        return group.id
    }

    func saveFileCopy(for entry: ClipboardEntry, using replacement: URL? = nil) async throws {
        guard entries.contains(where: { $0.id == entry.id }),
              entry.kind == .fileReference else { throw ClipboardHistoryStoreError.invalidSavedRecord }
        let source = replacement ?? liveOriginalAccess(for: entry)?.url ?? resolvedOriginalURL(for: entry)
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
        updated.ocrText = nil
        do { try requiredDatabase().upsert(updated) }
        catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        entries[currentIndex] = updated
        let oldOCR = ocrURL(for: entry.id)
        if fileManager.fileExists(atPath: oldOCR.path) { try? fileManager.removeItem(at: oldOCR) }
        if let oldCopy, oldCopy != destination { try? fileManager.removeItem(at: oldCopy) }
        let thumbnail = thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png")
        try? fileManager.removeItem(at: thumbnail)
        _ = try pruneEntries()
    }

    /// Restore a missing file reference with the user's newly granted URL.
    /// Keep only its location and bookmark; recovery must not copy file bytes.
    func relinkFileReference(_ entry: ClipboardEntry, to source: URL) throws {
        guard entry.kind == .fileReference,
              let index = entries.firstIndex(where: { $0.id == entry.id }),
              source.isFileURL else { throw ClipboardHistoryStoreError.invalidSavedRecord }
        let started = source.startAccessingSecurityScopedResource()
        defer { if started { source.stopAccessingSecurityScopedResource() } }
        let liveAccess = FilePreviewAccess(url: source, usesSecurityScope: true)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ClipboardHistoryStoreError.unsupportedFile
        }
        guard fileManager.isReadableFile(atPath: source.path),
              let bookmark = makeFileBookmark(for: source) else {
            throw ClipboardHistoryStoreError.fileReferenceUnavailable
        }
        let bookmarkName = "\(UUID().uuidString).bookmark"
        let bookmarkURL = bookmarksDirectory.appendingPathComponent(bookmarkName)
        try bookmark.write(to: bookmarkURL, options: .atomic)
        let oldEntry = entries[index]
        var updated = oldEntry
        updated.filePath = source.standardizedFileURL.path
        if oldEntry.filePath != updated.filePath {
            updated.digest = Self.relinkedFileDigest(for: updated.id)
        }
        updated.fileName = source.lastPathComponent
        updated.fileType = UTType(filenameExtension: source.pathExtension)?.identifier
        updated.fileBookmarkName = bookmarkName
        updated.byteCount = values.fileSize ?? 0
        // An unavailable saved copy should not keep a dead preference over the
        // newly accessible original. An available manual copy remains intact.
        if oldEntry.fileCopyName != nil && savedCopyURL(for: oldEntry) == nil {
            updated.fileCopyName = nil
        }
        do { try requiredDatabase().upsert(updated) }
        catch {
            try? fileManager.removeItem(at: bookmarkURL)
            throw error
        }
        entries[index] = updated
        if let liveAccess {
            liveOriginalFileAccesses[entry.id] = liveAccess
        } else {
            liveOriginalFileAccesses.removeValue(forKey: entry.id)
        }
        if let oldBookmarkName = oldEntry.fileBookmarkName,
           safeFileName(oldBookmarkName), oldBookmarkName != bookmarkName {
            try? fileManager.removeItem(at: bookmarksDirectory.appendingPathComponent(oldBookmarkName))
        }
    }

    /// Discard an optional local backup only while the original is reachable.
    func removeSavedFileCopy(for entry: ClipboardEntry) throws {
        guard entry.kind == .fileReference,
              let index = entries.firstIndex(where: { $0.id == entry.id }),
              savedCopyURL(for: entries[index]) != nil else {
            throw ClipboardHistoryStoreError.invalidSavedRecord
        }
        let current = entries[index]
        let copy = savedCopyURL(for: current)
        guard originalFileCanBeReused(current),
              withOriginalFileURL(for: current, { original in
            original.standardizedFileURL != copy?.standardizedFileURL
        }) == true else {
            throw ClipboardHistoryStoreError.fileReferenceUnavailable
        }
        var updated = current
        updated.fileCopyName = nil
        updated.ocrText = nil
        try requiredDatabase().upsert(updated)
        entries[index] = updated
        let folder = fileCopiesDirectory.appendingPathComponent(current.id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            do { try fileManager.removeItem(at: folder) }
            catch {
                try? requiredDatabase().upsert(current)
                entries[index] = current
                throw error
            }
        }
        try? fileManager.removeItem(at: thumbnailsDirectory.appendingPathComponent("\(current.id.uuidString).png"))
        try? fileManager.removeItem(at: ocrURL(for: current.id))
    }

    @discardableResult func applyStoragePolicy() throws -> Bool { try pruneEntries() }

    func cardOrderEntries(in scope: ClipboardCardOrderScope) -> [ClipboardEntry] {
        switch scope {
        case .history:
            return ClipboardCardReordering.sorted(rootEntries.filter { $0.shelfPinOrder == nil }, in: scope)
        case .favorite(let id):
            let tab = ClipboardShelfNavigation.Tab.favoriteCategory(id)
            let included = rootEntries.filter { $0.shelfPinOrder == nil && !tab.members(of: $0).isEmpty }
            return ClipboardCardReordering.sorted(included, in: scope)
        case .pins:
            return rootEntries.filter { $0.shelfPinOrder != nil }.sorted {
                ($0.shelfPinOrder ?? 0) > ($1.shelfPinOrder ?? 0)
            }
        case .group(let id):
            guard let group = entries.first(where: { $0.id == id && $0.kind == .group }) else { return [] }
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            return group.groupMemberIDs.compactMap { byID[$0] }.filter { $0.shelfPinOrder == nil }
        }
    }

    func canReorderCards(_ ids: [UUID], in scope: ClipboardCardOrderScope) -> Bool {
        !ids.isEmpty && Set(ids).isSubset(of: Set(cardOrderEntries(in: scope).map(\.id)))
    }

    @discardableResult
    func reorderCards(_ ids: [UUID], relativeTo target: UUID, after: Bool,
                      in scope: ClipboardCardOrderScope) throws -> Bool {
        let current = cardOrderEntries(in: scope)
        guard let order = ClipboardCardReordering.moving(ids, relativeTo: target, after: after,
                                                       in: current.map(\.id)) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let reordered = order.compactMap { byID[$0] }
        let database = try requiredDatabase()
        if let key = scope.storageKey {
            try database.transaction { try database.saveCardOrder(reordered, scope: key) }
            let ranks = Dictionary(uniqueKeysWithValues: reordered.enumerated().map {
                ($0.element.id, ClipboardCardOrder(position: Int64($0.offset), copiedAt: $0.element.createdAt))
            })
            for index in entries.indices { entries[index].cardOrders[key] = ranks[entries[index].id] }
        } else if scope == .pins {
            let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map {
                ($0.element, Int64(order.count - $0.offset))
            })
            try database.transaction { try database.saveShelfPinOrder(order) }
            for index in entries.indices where ranks[entries[index].id] != nil {
                entries[index].shelfPinOrder = ranks[entries[index].id]
            }
        } else if case .group(let id) = scope,
                  let index = entries.firstIndex(where: { $0.id == id }) {
            var group = entries[index]
            // Keep pinned members in their original slots while moving the
            // visible, unpinned members within this group only.
            var remaining = order.makeIterator()
            let moving = Set(order)
            group.groupMemberIDs = group.groupMemberIDs.map { moving.contains($0) ? remaining.next()! : $0 }
            try database.transaction { try database.upsert(group) }
            entries[index] = group
        }
        return true
    }

    @discardableResult
    func setShelfPinned(_ ids: [UUID], pinned: Bool) throws -> Int {
        let indexByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        var seen: Set<UUID> = []
        let indexes = try ids.compactMap { id -> Int? in
            guard seen.insert(id).inserted else { return nil }
            guard let index = indexByID[id] else { throw ClipboardHistoryStoreError.historyEntryMissing }
            let isPinned = entries[index].shelfPinOrder != nil
            return isPinned == pinned ? nil : index
        }
        guard !indexes.isEmpty else { return 0 }
        let database = try requiredDatabase()
        var updates: [(index: Int, position: Int64?)] = []
        try database.transaction {
            // Larger positions appear first. Keep the selection in its displayed order.
            for index in indexes.reversed() {
                let position = try database.setShelfPinned(pinned, for: entries[index].id)
                updates.append((index, position))
            }
        }
        for (index, position) in updates { entries[index].shelfPinOrder = position }
        return updates.count
    }

    func saveFavoriteCategory(name: String, tint: ClipboardFavoriteCategory.Tint,
                              icon: ClipboardFavoriteCategory.Icon, editing id: UUID?,
                              collecting entryIDs: Set<UUID> = []) throws -> ClipboardFavoriteCategory {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ClipboardHistoryStoreError.favoriteCategoryEmpty }
        guard name != "历史", !favoriteCategories.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw ClipboardHistoryStoreError.favoriteCategoryNameTaken }
        let index = id.flatMap { id in favoriteCategories.firstIndex { $0.id == id } }
        if id != nil && index == nil { throw ClipboardHistoryStoreError.favoriteCategoryMissing }
        let category = ClipboardFavoriteCategory(id: id ?? UUID(), name: name, tint: tint, icon: icon)
        let updates = favoriteUpdates(entryIDs) { entry in
            entry.isFavorite = true
            entry.favoriteCategoryID = category.id
        }
        guard updates.count == entryIDs.count else { throw ClipboardHistoryStoreError.historyEntryMissing }
        let database = try requiredDatabase()
        try database.transaction {
            try database.saveFavoriteCategory(category)
            for (_, entry) in updates { try database.upsert(entry) }
        }
        for (index, entry) in updates { entries[index] = entry }
        if let index { favoriteCategories[index] = category }
        else { favoriteCategories.append(category) }
        return category
    }

    func deleteFavoriteCategory(_ id: UUID) throws {
        let database = try requiredDatabase()
        try database.transaction { try database.deleteFavoriteCategory(id) }
        favoriteCategories.removeAll { $0.id == id }
        for index in entries.indices { entries[index].cardOrders["favorite:\(id.uuidString)"] = nil }
        for index in entries.indices where entries[index].favoriteCategoryID == id {
            entries[index].favoriteCategoryID = nil
            entries[index].cardOrders = entries[index].cardOrders.filter { !$0.key.hasPrefix("favorite:") }
        }
    }

    func setFavorites(_ ids: Set<UUID>, isFavorite: Bool) throws {
        try updateFavorites(ids) { entry in
            entry.isFavorite = isFavorite
            if !isFavorite { entry.favoriteCategoryID = nil }
        }
    }

    func moveFavorites(_ ids: Set<UUID>, to categoryID: UUID) throws {
        guard favoriteCategories.contains(where: { $0.id == categoryID }) else {
            throw ClipboardHistoryStoreError.favoriteCategoryMissing
        }
        try updateFavorites(ids) { entry in
            entry.isFavorite = true
            entry.favoriteCategoryID = categoryID
        }
    }

    private func favoriteUpdates(_ ids: Set<UUID>, update: (inout ClipboardEntry) -> Void)
        -> [(index: Int, entry: ClipboardEntry)] {
        guard !ids.isEmpty else { return [] }
        return entries.enumerated().compactMap { index, entry in
            guard ids.contains(entry.id) else { return nil }
            var updated = entry
            update(&updated)
            if updated.favoriteCategoryID != entry.favoriteCategoryID {
                updated.cardOrders = updated.cardOrders.filter { !$0.key.hasPrefix("favorite:") }
            }
            return (index, updated)
        }
    }

    private func updateFavorites(_ ids: Set<UUID>, update: (inout ClipboardEntry) -> Void) throws {
        let updates = favoriteUpdates(ids, update: update).filter { $0.entry != entries[$0.index] }
        let database = try requiredDatabase()
        try database.transaction {
            for (_, entry) in updates { try database.upsert(entry) }
        }
        for (index, entry) in updates { entries[index] = entry }
    }

    /// Favorites and shelf pins protect their payloads. Only favorites on
    /// individual members also protect the groups containing those members.
    private var protectedHistoryIDs: Set<UUID> {
        let favorites = Set(entries.filter(\.isFavorite).map(\.id))
        var protected = favorites.union(entries.lazy.filter { $0.shelfPinOrder != nil }.map(\.id))
        for group in entries where group.kind == .group &&
            (protected.contains(group.id) || group.groupMemberIDs.contains(where: favorites.contains)) {
            protected.insert(group.id)
            protected.formUnion(group.groupMemberIDs)
        }
        return protected
    }

    func delete(_ entry: ClipboardEntry) throws {
        guard let current = entries.first(where: { $0.id == entry.id }) else { return }
        let database = try requiredDatabase()
        var changedGroups: [ClipboardEntry] = []
        var dissolvedIDs: Set<UUID> = []
        if current.kind != .group {
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            for group in entries where group.kind == .group && group.groupMemberIDs.contains(current.id) {
                let updated = refreshedGroup(
                    group,
                    memberIDs: group.groupMemberIDs.filter { $0 != current.id },
                    byID: byID
                )
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
        liveOriginalFileAccesses.removeValue(forKey: current.id)
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
        liveOriginalFileAccesses.removeAll()
        for entry in removed { try removePayload(for: entry) }
    }

    /// Record a successful reuse of a saved entry. The app marks its own
    /// pasteboard writes as handled, so the regular clipboard poll will not
    /// refresh this entry for us.
    func recordCopy(of id: UUID) throws -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        var entry = entries[index]
        let recordedAt = now()
        entry.recordedAt = entry.calendarRecordTimes + [recordedAt]
        entry.createdAt = max(now(), (entries.first?.createdAt ?? .distantPast).addingTimeInterval(0.001))
        // Legacy entries have no trustworthy historical total. Start counting
        // their known reuses without inventing an original copy date.
        entry.copyCount = (entry.copyCount ?? 0) + 1
        let database = try requiredDatabase()
        var members = entries.filter { entry.groupMemberIDs.contains($0.id) }
        for index in members.indices {
            members[index].recordedAt = members[index].calendarRecordTimes + [recordedAt]
        }
        // SAVEPOINT also works inside recordBatchCopy's existing transaction.
        // The group and member dates must survive a later ungroup operation.
        try database.withSavepoint {
            try database.upsert(entry)
            for member in members { try database.upsert(member) }
        }
        for member in members {
            if let index = entries.firstIndex(where: { $0.id == member.id }) { entries[index] = member }
        }
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
        if blockedByLegacyIndex { throw ClipboardHistoryStoreError.legacyWriterDetected }
        guard let database else { throw ClipboardHistoryStoreError.unavailable }
        if fileManager.fileExists(atPath: legacyIndexURL.path) {
            throw ClipboardHistoryStoreError.legacyWriterDetected
        }
        return database
    }

    private func refreshExisting(digest: String, sourceAppName: String?, sourceAppBundleID: String?,
                                 screenshotOrigin: ClipboardScreenshotOrigin? = nil) throws -> Bool {
        guard let index = entries.firstIndex(where: { $0.digest == digest }) else { return false }
        var entry = entries[index]
        let previousOrigin = entry.resolvedScreenshotOrigin
        entry.recordedAt = entry.calendarRecordTimes + [now()]
        entry.createdAt = now()
        if let copyCount = entry.copyCount {
            entry.copyCount = copyCount + 1
        }
        entry.sourceAppName = sourceAppName
        entry.sourceAppBundleID = sourceAppBundleID
        if entry.isImagePreviewable && entry.screenshotOrigin != .ordinaryImage {
            entry.screenshotOrigin = screenshotOrigin ?? previousOrigin
        }
        try requiredDatabase().upsert(entry)
        entries.remove(at: index)
        insertNewestFirst(entry)
        return true
    }

    func setScreenshotOrigin(_ origin: ClipboardScreenshotOrigin, for id: UUID) throws -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].isImagePreviewable || entries[index].kind == .unavailableImage else { return false }
        var entry = entries[index]
        entry.screenshotOrigin = origin
        guard try requiredDatabase().updateScreenshotOrigin(origin, for: id) else { return false }
        entries[index] = entry
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
        let protected = protectedHistoryIDs
        let groupedMemberIDs = Set(entries.filter { $0.kind == .group }.flatMap(\.groupMemberIDs))
        var candidates = rootEntries.filter { !protected.contains($0.id) }
        var changed = false
        func remove(_ entry: ClipboardEntry) throws {
            try delete(entry)
            changed = true
            // Deleting a group, or a member that dissolves one, can reveal
            // older cards. Rebuild only in that case to preserve deletion order.
            if entry.kind == .group || groupedMemberIDs.contains(entry.id) {
                candidates = rootEntries.filter { !protected.contains($0.id) }
            }
        }
        if let cutoff = policy.cutoff(before: now(), calendar: calendar) {
            while let oldest = candidates.last, oldest.createdAt < cutoff {
                candidates.removeLast()
                try remove(oldest)
            }
        }
        if let maxBytes = policy.maximumBytes {
            var usage = payloadUsage()
            if usage.totalBytes + diskBytes(at: databaseURL) > Int64(maxBytes) {
                try moveUnreferencedPayloadsToRecovery()
                usage = payloadUsage()
            }
            // Count the payload directories once, then subtract each removed
            // record's files. SQLite's changing allocation needs only a stat.
            while usage.totalBytes + diskBytes(at: databaseURL) > Int64(maxBytes),
                  let oldest = candidates.popLast() {
                let removedURLs = payloadURLs(for: oldest)
                try remove(oldest)
                usage.remove(removedURLs)
            }
        }
        return changed
    }

    private func textURL(for entry: ClipboardEntry) -> URL {
        contentDirectory.appendingPathComponent(entry.textFileName)
    }

    private func richTextURLs(for entry: ClipboardEntry) -> [URL] {
        [entry.rtfFileName, entry.htmlFileName, entry.rtfdFileName].compactMap { name in
            guard let name, safeFileName(name) else { return nil }
            return richTextDirectory.appendingPathComponent(name)
        }
    }

    private func savedCopyURL(for entry: ClipboardEntry) -> URL? {
        guard let name = entry.fileCopyName, safeFileName(name) else { return nil }
        let url = fileCopiesDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
            .appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) && fileManager.isReadableFile(atPath: url.path)
            ? url : nil
    }

    private func resolvedOriginalURL(for entry: ClipboardEntry) -> URL? {
        let expectedPath = entry.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if let name = entry.fileBookmarkName, safeFileName(name),
           let data = try? Data(contentsOf: bookmarksDirectory.appendingPathComponent(name)) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ), url.isFileURL, !stale,
               expectedPath == nil || url.standardizedFileURL.path == expectedPath { return url }
            stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: [],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ), url.isFileURL, !stale,
               expectedPath == nil || url.standardizedFileURL.path == expectedPath { return url }
        }
        guard let path = entry.filePath, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func makeFileBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        ) { return scoped }
        return try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
    }

    private static func relinkedFileDigest(for id: UUID) -> String {
        digest(data: Data(id.uuidString.utf8), prefix: "relinked-file-reference")
    }

    private func removePayload(for entry: ClipboardEntry) throws {
        for url in payloadURLs(for: entry) where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func payloadUsage() -> HistoryPayloadUsage {
        var usage = HistoryPayloadUsage()
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                       .fileSizeKey, .isRegularFileKey]
        for folder in payloadDirectories {
            guard let enumerator = fileManager.enumerator(at: folder,
                    includingPropertiesForKeys: Array(keys)) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                usage.totalBytes += size
                // Enumerators may canonicalize /var to /private/var. Rebuild
                // the logical path from its depth so lookup uses the exact
                // same root as payloadURLs, without resolving every file.
                var logicalURL = folder
                for component in url.pathComponents.suffix(enumerator.level) {
                    logicalURL.appendPathComponent(component)
                }
                usage.bytesByPath[logicalURL.path] = size
                // Saved file copies and RTFD payloads may contain directories.
                // Cache their size too, without rescanning them on deletion.
                var parent = logicalURL.deletingLastPathComponent()
                while parent.path != folder.path && parent.path != "/" {
                    usage.bytesByPath[parent.path, default: 0] += size
                    parent.deleteLastPathComponent()
                }
            }
        }
        return usage
    }

    /// Use the same file list for accounting and deletion, including optional
    /// caches, legacy sidecars and nested saved file copies.
    private func payloadURLs(for entry: ClipboardEntry) -> [URL] {
        var urls: [URL] = []
        if entry.kind == .image {
            if let name = entry.imageFileName, safeFileName(name) {
                urls.append(imagesDirectory.appendingPathComponent(name))
            }
        } else if entry.kind.isTextual {
            urls.append(textURL(for: entry))
        }
        urls.append(contentsOf: richTextURLs(for: entry))
        if let name = entry.fileBookmarkName, safeFileName(name) {
            urls.append(bookmarksDirectory.appendingPathComponent(name))
        }
        urls.append(fileCopiesDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true))
        urls.append(thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png"))
        urls.append(ocrURL(for: entry.id))
        urls.append(screenshotBasesDirectory.appendingPathComponent("\(entry.id.uuidString).image"))
        urls.append(screenshotAnnotationsDirectory.appendingPathComponent("\(entry.id.uuidString).json"))
        urls.append(screenshotEditURL(for: entry.id))
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0).inserted }
    }

    private func moveUnreferencedPayloadsToRecovery() throws {
        let textNames = Set(entries.filter { $0.kind.isTextual }.map(\.textFileName))
        let imageNames = Set(entries.compactMap(\.imageFileName))
        let screenshotBaseNames = Set(entries.filter { $0.kind == .image }.map { "\($0.id.uuidString).image" })
        let screenshotAnnotationNames = Set(entries.filter { $0.kind == .image }.flatMap {
            ["\($0.id.uuidString).json", "\($0.id.uuidString).plist"]
        })
        let richNames = Set(entries.flatMap { [$0.rtfFileName, $0.htmlFileName, $0.rtfdFileName].compactMap { $0 } })
        let bookmarkNames = Set(entries.compactMap(\.fileBookmarkName))
        let thumbnailNames = Set(entries.filter { $0.kind == .fileReference }.map { "\($0.id.uuidString).png" })
        let ocrNames = Set(entries.filter { $0.ocrText != nil }.map { "\($0.id.uuidString).json" })
        let copyFolderNames = Set(entries.filter { $0.fileCopyName != nil }.map { $0.id.uuidString })
        for (folder, names) in [
            (contentDirectory, textNames), (imagesDirectory, imageNames),
            (screenshotBasesDirectory, screenshotBaseNames),
            (screenshotAnnotationsDirectory, screenshotAnnotationNames),
            (richTextDirectory, richNames), (bookmarksDirectory, bookmarkNames),
            (thumbnailsDirectory, thumbnailNames), (fileCopiesDirectory, copyFolderNames),
            (ocrDirectory, ocrNames)
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
                try Data((entry.text ?? "").utf8).write(to: textURL(for: entry), options: .atomic)
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
