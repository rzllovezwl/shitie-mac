import CryptoKit
import Foundation

@MainActor
final class ClipboardHistoryStore {
    private let fileManager = FileManager.default
    private let directory: URL
    private let imagesDirectory: URL
    private let indexURL: URL

    private(set) var entries: [ClipboardEntry] = []
    private(set) var errorMessage: String?

    private let maximumEntries = 100
    private let maximumTotalBytes = 100 * 1_024 * 1_024
    let maximumImageBytes = 15 * 1_024 * 1_024
    let maximumTextBytes = 1 * 1_024 * 1_024

    init(directory overrideDirectory: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = overrideDirectory ?? support.appendingPathComponent("ClipboardShelf", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        indexURL = directory.appendingPathComponent("history.json")

        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: indexURL.path) {
                let data = try Data(contentsOf: indexURL)
                entries = try JSONDecoder().decode([ClipboardEntry].self, from: data)
                entries.removeAll { entry in
                    guard let fileName = entry.imageFileName else { return false }
                    return !fileManager.fileExists(atPath: imagesDirectory.appendingPathComponent(fileName).path)
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
            try save()
            return true
        }

        entries.insert(
            ClipboardEntry(
                id: UUID(), createdAt: .now, kind: kind, text: text,
                imageFileName: nil, imagePasteboardType: nil, digest: digest,
                byteCount: data.count, sourceAppName: sourceAppName
            ), at: 0
        )
        prune()
        try save()
        return true
    }

    func addImage(_ data: Data, type: String, sourceAppName: String?) throws -> Bool {
        guard !data.isEmpty, data.count <= maximumImageBytes else { return false }
        let digest = Self.digest(data: data, prefix: "image")
        if refreshExisting(digest: digest, sourceAppName: sourceAppName) {
            try save()
            return true
        }

        let id = UUID()
        let extensionName = type == "public.png" ? "png" : "tiff"
        let fileName = "\(id.uuidString).\(extensionName)"
        try data.write(to: imagesDirectory.appendingPathComponent(fileName), options: .atomic)
        entries.insert(
            ClipboardEntry(
                id: id, createdAt: .now, kind: .image, text: nil,
                imageFileName: fileName, imagePasteboardType: type, digest: digest,
                byteCount: data.count, sourceAppName: sourceAppName
            ), at: 0
        )
        prune()
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
        entry.createdAt = .now
        entry.sourceAppName = sourceAppName
        entries.insert(entry, at: 0)
        return true
    }

    private func prune() {
        var totalBytes = entries.reduce(0) { $0 + $1.byteCount }
        while entries.count > maximumEntries || totalBytes > maximumTotalBytes {
            let removed = entries.removeLast()
            totalBytes -= removed.byteCount
            removeImage(for: removed)
        }
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
