import CryptoKit
import Foundation

enum ClipboardHistoryStoreError: LocalizedError {
    case unavailable, invalidLegacyRecord, migrationVerificationFailed, legacyWriterDetected, invalidSavedRecord

    var errorDescription: String? {
        switch self {
        case .unavailable: "历史记录尚未准备好；旧记录未被修改。"
        case .invalidLegacyRecord: "旧记录或图片不完整，迁移已停止。"
        case .migrationVerificationFailed: "历史记录迁移校验失败，旧记录未被修改。"
        case .legacyWriterDetected: "检测到旧版仍在写入 history.json；请先退出旧版，避免两份历史分叉。"
        case .invalidSavedRecord: "已保存记录的内容位置无效。"
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
    private let databaseURL: URL
    private let legacyIndexURL: URL
    private let migrationBackupURL: URL
    private let recoveryDirectory: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar
    private var database: ClipboardHistoryDatabase?

    private(set) var entries: [ClipboardEntry] = []
    private(set) var errorMessage: String?
    let maximumImageBytes = 15 * 1_024 * 1_024
    let maximumTextBytes = 1 * 1_024 * 1_024

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
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        contentDirectory = directory.appendingPathComponent("Content", isDirectory: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        legacyIndexURL = directory.appendingPathComponent("history.json")
        migrationBackupURL = directory.appendingPathComponent("LegacyMigrationBackup", isDirectory: true)
        recoveryDirectory = directory.appendingPathComponent("UnreferencedRecovery", isDirectory: true)
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
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
    }

    var migrationBackupBytes: Int64 { diskBytes(in: migrationBackupURL) }
    var recoveryBytes: Int64 { diskBytes(in: recoveryDirectory) }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let name = entry.imageFileName, safeFileName(name) else { return nil }
        let url = imagesDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func addText(_ text: String, sourceAppName: String?, sourceAppBundleID: String? = nil) throws -> Bool {
        guard !text.isEmpty else { return false }
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else { return false }
        _ = try requiredDatabase()
        let kind: ClipboardEntry.Kind = Self.isWebLink(text) ? .link : .text
        let digest = Self.digest(data: data, prefix: kind.rawValue)
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

    func addImage(_ data: Data, type: String, sourceAppName: String?, sourceAppBundleID: String? = nil) throws -> Bool {
        guard !data.isEmpty, data.count <= maximumImageBytes else { return false }
        _ = try requiredDatabase()
        let digest = Self.digest(data: data, prefix: "image")
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
        let name = "\(id.uuidString).\(type == "public.png" ? "png" : "tiff")"
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

    @discardableResult func applyStoragePolicy() throws -> Bool { try pruneEntries() }

    func delete(_ entry: ClipboardEntry) throws {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        try requiredDatabase().delete(entry.id)
        entries.removeAll { $0.id == entry.id }
        try removePayload(for: entry)
    }

    func clear() throws {
        let removed = entries
        try requiredDatabase().deleteAll()
        entries.removeAll()
        for entry in removed { try removePayload(for: entry) }
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
        if entry.firstCopiedAt != nil {
            entry.copyCount = (entry.copyCount ?? 1) + 1
        }
        entry.sourceAppName = sourceAppName
        entry.sourceAppBundleID = sourceAppBundleID
        try requiredDatabase().upsert(entry)
        entries.remove(at: index)
        insertNewestFirst(entry)
        return true
    }

    private func insertNewestFirst(_ entry: ClipboardEntry) {
        let index = entries.firstIndex { $0.createdAt <= entry.createdAt } ?? entries.endIndex
        entries.insert(entry, at: index)
    }

    private func pruneEntries() throws -> Bool {
        _ = try requiredDatabase()
        let policy = HistoryStoragePolicy(defaults: defaults)
        var changed = false
        if let cutoff = policy.cutoff(before: now(), calendar: calendar) {
            for entry in entries.filter({ $0.createdAt < cutoff }) {
                try delete(entry)
                changed = true
            }
        }
        if let maxBytes = policy.maximumBytes {
            if activeStorageBytes > Int64(maxBytes) { try moveUnreferencedPayloadsToRecovery() }
            while activeStorageBytes > Int64(maxBytes), let oldest = entries.last {
                try delete(oldest)
                changed = true
            }
        }
        return changed
    }

    private func textURL(for id: UUID) -> URL {
        contentDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    private func removePayload(for entry: ClipboardEntry) throws {
        if entry.kind == .image {
            if let url = imageURL(for: entry) { try fileManager.removeItem(at: url) }
        } else {
            let url = textURL(for: entry.id)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    private func moveUnreferencedPayloadsToRecovery() throws {
        let textNames = Set(entries.filter { $0.kind != .image }.map { "\($0.id.uuidString).txt" })
        let imageNames = Set(entries.compactMap(\.imageFileName))
        for (folder, names) in [(contentDirectory, textNames), (imagesDirectory, imageNames)] {
            for url in try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where !names.contains(url.lastPathComponent) {
                let destinationFolder = recoveryDirectory.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
                try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                var destination = destinationFolder.appendingPathComponent(url.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    destination = destinationFolder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                }
                try fileManager.moveItem(at: url, to: destination)
            }
        }
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

    private static func isWebLink(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme == "https" || url.scheme == "http"
    }
}
