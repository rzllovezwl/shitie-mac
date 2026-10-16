import CryptoKit
import Foundation

@MainActor
final class ClipboardHistoryStore {
    private let fileManager = FileManager.default
    private let directory: URL
    private let imagesDirectory: URL
    private let indexURL: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let calendar: Calendar

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
        indexURL = directory.appendingPathComponent("history.json")

        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: indexURL.path) {
                let data = try Data(contentsOf: indexURL)
                entries = try JSONDecoder().decode([ClipboardEntry].self, from: data)
                let loadedEntries = entries
                entries.removeAll { entry in
                    guard let fileName = entry.imageFileName else { return false }
                    return !fileManager.fileExists(atPath: imagesDirectory.appendingPathComponent(fileName).path)
                }
                entries.sort { $0.createdAt > $1.createdAt }
                let wasPruned = pruneEntries()
                if entries != loadedEntries || wasPruned {
                    try save()
                }
            }
        } catch {
            errorMessage = "无法读取历史记录：\(error.localizedDescription)"
        }
    }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let fileName = entry.imageFileName else { return nil }
        return imagesDirectory.appendingPathComponent(fileName)
    }

    func addText(_ text: String, sourceAppName: String?) throws -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else { return false }
        let kind: ClipboardEntry.Kind = Self.isWebLink(text) ? .link : .text
        let digest = Self.digest(data: data, prefix: kind.rawValue)
        if refreshExisting(digest: digest, sourceAppName: sourceAppName) {
            _ = pruneEntries()
            try save()
            return true
        }

        insertNewestFirst(
            ClipboardEntry(
                id: UUID(), createdAt: now(), kind: kind, text: text,
                imageFileName: nil, imagePasteboardType: nil, digest: digest,
                byteCount: data.count, sourceAppName: sourceAppName
            )
        )
        _ = pruneEntries()
        try save()
        return true
    }

    func addImage(_ data: Data, type: String, sourceAppName: String?) throws -> Bool {
        guard !data.isEmpty, data.count <= maximumImageBytes else { return false }
        let digest = Self.digest(data: data, prefix: "image")
        if refreshExisting(digest: digest, sourceAppName: sourceAppName) {
            _ = pruneEntries()
            try save()
            return true
        }

        let id = UUID()
        let extensionName = type == "public.png" ? "png" : "tiff"
        let fileName = "\(id.uuidString).\(extensionName)"
        try data.write(to: imagesDirectory.appendingPathComponent(fileName), options: .atomic)
        insertNewestFirst(
            ClipboardEntry(
                id: id, createdAt: now(), kind: .image, text: nil,
                imageFileName: fileName, imagePasteboardType: type, digest: digest,
                byteCount: data.count, sourceAppName: sourceAppName
            )
        )
        _ = pruneEntries()
        try save()
        return true
    }

    @discardableResult
    func applyStoragePolicy() throws -> Bool {
        guard pruneEntries() else { return false }
        try save()
        return true
    }

    func clear() throws {
        for entry in entries {
            removeImage(for: entry)
        }
        entries.removeAll()
        try save()
    }

    private func refreshExisting(digest: String, sourceAppName: String?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.digest == digest }) else { return false }
        var entry = entries.remove(at: index)
        entry.createdAt = now()
        entry.sourceAppName = sourceAppName
        insertNewestFirst(entry)
        return true
    }

    private func insertNewestFirst(_ entry: ClipboardEntry) {
        let index = entries.firstIndex { $0.createdAt <= entry.createdAt } ?? entries.endIndex
        entries.insert(entry, at: index)
    }

    private func pruneEntries() -> Bool {
        let policy = HistoryStoragePolicy(defaults: defaults)
        var changed = false

        if let cutoff = policy.cutoff(before: now(), calendar: calendar) {
            let expired = entries.filter { $0.createdAt < cutoff }
            if !expired.isEmpty {
                entries.removeAll { $0.createdAt < cutoff }
                expired.forEach { removeImage(for: $0) }
                changed = true
            }
        }

        guard let maximumBytes = policy.maximumBytes else { return changed }
        var totalBytes = entries.reduce(0) { $0 + max(0, $1.byteCount) }
        while totalBytes > maximumBytes, !entries.isEmpty {
            let removed = entries.removeLast()
            totalBytes -= max(0, removed.byteCount)
            removeImage(for: removed)
            changed = true
        }
        return changed
    }

    private func removeImage(for entry: ClipboardEntry) {
        guard let imageURL = imageURL(for: entry) else { return }
        try? fileManager.removeItem(at: imageURL)
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: indexURL, options: .atomic)
        errorMessage = nil
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
