import AppKit
import Foundation
import ImageIO

struct PinnedWindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ frame: NSRect) {
        x = frame.origin.x
        y = frame.origin.y
        width = frame.width
        height = frame.height
    }

    var rect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

struct PinnedImageRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let sourceEntryID: UUID
    let fileName: String
    let title: String
    var frame: PinnedWindowFrame?
    var allSpaces: Bool
}

enum PinnedImageError: LocalizedError {
    case imageUnavailable, imageTooLarge, invalidImage, unreadableIndex, missingSnapshot

    var errorDescription: String? {
        switch self {
        case .imageUnavailable: "图片文件不可用，无法钉在桌面。"
        case .imageTooLarge: "图片超过 100 MB，无法钉在桌面。"
        case .invalidImage: "这不是可显示的图片，无法钉在桌面。"
        case .unreadableIndex: "贴图记录无法读取；已有贴图文件未被修改。"
        case .missingSnapshot: "这张贴图的保存副本已丢失，无法显示。"
        }
    }
}

/// Owns snapshots independently of the history retention policy. Explicit
/// history deletion may remove a pin, but automatic history pruning does not.
@MainActor
final class PinnedImageStore {
    private let manager = FileManager.default
    private let directory: URL
    private let indexURL: URL
    private(set) var records: [PinnedImageRecord]

    init(directory: URL) throws {
        self.directory = directory
        indexURL = directory.appendingPathComponent("pins.json")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: indexURL.path) {
            guard let data = try? Data(contentsOf: indexURL),
                  let decoded = try? JSONDecoder().decode([PinnedImageRecord].self, from: data),
                  Set(decoded.map(\.id)).count == decoded.count,
                  Set(decoded.map(\.sourceEntryID)).count == decoded.count,
                  decoded.allSatisfy({ record in
                      let prefix = record.id.uuidString + "."
                      let suffix = record.fileName.dropFirst(prefix.count)
                      return record.fileName.hasPrefix(prefix) && !suffix.isEmpty
                          && suffix.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
                  }) else {
                throw PinnedImageError.unreadableIndex
            }
            records = decoded
        } else {
            records = []
        }
    }

    var count: Int { records.count }

    var storageBytes: Int64 {
        let urls = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func record(for sourceEntryID: UUID) -> PinnedImageRecord? {
        records.first { $0.sourceEntryID == sourceEntryID }
    }

    func imageURL(for record: PinnedImageRecord) -> URL? {
        let url = directory.appendingPathComponent(record.fileName)
        return manager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func add(sourceEntryID: UUID, sourceURL: URL, title: String) throws -> PinnedImageRecord {
        if let existing = record(for: sourceEntryID) {
            guard imageURL(for: existing) != nil else { throw PinnedImageError.missingSnapshot }
            return existing
        }
        guard manager.isReadableFile(atPath: sourceURL.path),
              let attributes = try? manager.attributesOfItem(atPath: sourceURL.path),
              let size = attributes[.size] as? NSNumber else {
            throw PinnedImageError.imageUnavailable
        }
        guard size.int64Value <= 100 * 1_024 * 1_024 else { throw PinnedImageError.imageTooLarge }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              NSImage(contentsOf: sourceURL) != nil else { throw PinnedImageError.invalidImage }

        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(ext)"
        let destination = directory.appendingPathComponent(fileName)
        // Write the bytes as a regular file. FileManager.copyItem can copy a
        // symbolic link itself, which would make a pin depend on the original.
        let bytes = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try bytes.write(to: destination, options: .atomic)
        let record = PinnedImageRecord(
            id: id, sourceEntryID: sourceEntryID, fileName: fileName,
            title: title, frame: nil, allSpaces: false
        )
        do {
            try save(records + [record])
            records.append(record)
            return record
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    func updateFrame(_ frame: NSRect, for id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var updated = records
        updated[index].frame = PinnedWindowFrame(frame)
        try save(updated)
        records = updated
    }

    func setAllSpaces(_ enabled: Bool, for id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var updated = records
        updated[index].allSpaces = enabled
        try save(updated)
        records = updated
    }

    func remove(_ id: UUID) throws {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let original = directory.appendingPathComponent(record.fileName)
        let staged = directory.appendingPathComponent(".removing-\(id.uuidString)")
        let exists = manager.fileExists(atPath: original.path)
        if exists { try manager.moveItem(at: original, to: staged) }
        do {
            let updated = records.filter { $0.id != id }
            try save(updated)
            records = updated
            if exists { try? manager.removeItem(at: staged) }
        } catch {
            if exists { try? manager.moveItem(at: staged, to: original) }
            throw error
        }
    }

    private func save(_ updated: [PinnedImageRecord]) throws {
        let data = try JSONEncoder().encode(updated)
        try data.write(to: indexURL, options: .atomic)
    }
}
