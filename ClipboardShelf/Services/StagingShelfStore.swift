import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum StagingShelfError: LocalizedError {
    case unavailable, unsupported, tooManyItems, tooLarge, duplicateText, missingFile(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "暂存数据无法读取，现有内容未被修改。"
        case .unsupported: "无法暂存这类内容，请先将它保存为本机文件。"
        case .tooManyItems: "暂存箱最多保留 100 项，请移除一些内容后再试。"
        case .tooLarge: "图片或文字超出暂存容量，请先保存为文件，再拖入文件。"
        case .duplicateText: "相同内容已在暂存箱中。"
        case .missingFile(let name): "无法访问「\(name)」，请从访达重新拖入该文件。"
        }
    }
}

/// A preview owns its recognition state and security scope. OCR does not need
/// to import a staging item into clipboard history to use the shared UI.
@MainActor
final class StagingShelfPreviewSession: ObservableObject {
    private(set) var payload: StagingShelfPreviewPayload
    @Published private(set) var entry: ClipboardEntry
    @Published private(set) var isRecognizing = false
    @Published private(set) var ocrError: String?
    @Published private(set) var actionRequest: ClipboardPreviewActionRequest?
    private var recognition: Task<Void, Never>?
    private var generation = UUID()
    private let recognizer: @Sendable (URL) async throws -> String

    init(_ payload: StagingShelfPreviewPayload,
         recognizer: @escaping @Sendable (URL) async throws -> String = { try await ImageOCRService.recognize(at: $0) }) {
        self.payload = payload; entry = payload.previewEntry; self.recognizer = recognizer
    }
    var canUseImage: Bool { entry.kind == .image }

    func update(_ payload: StagingShelfPreviewPayload) {
        guard payload.id == entry.id else { return }
        let next = payload.previewEntry
        if next.text != entry.text || next.filePath != entry.filePath {
            cancelRecognition()
            entry = next
            entry.textRevision = UUID()
        }
        self.payload = payload
    }

    func request(_ action: AppShortcutAction) {
        actionRequest = ClipboardPreviewActionRequest(entryID: entry.id, action: action)
    }

    @discardableResult
    func recognize() -> Task<Void, Never>? {
        guard canUseImage, !isRecognizing, case .file(let url) = payload.content else { return nil }
        isRecognizing = true
        ocrError = nil
        let token = UUID()
        generation = token
        let access = payload.access
        let recognizer = recognizer
        recognition = Task { @MainActor [weak self, access] in
            defer { withExtendedLifetime(access) {} }
            do {
                let text = try await recognizer(url)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.entry.ocrText = text
                self.isRecognizing = false
                self.recognition = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.ocrError = error.localizedDescription
                self.isRecognizing = false
                self.recognition = nil
            }
        }
        return recognition
    }

    func cancelRecognition() {
        generation = UUID()
        recognition?.cancel()
        recognition = nil
        isRecognizing = false
    }

    deinit { recognition?.cancel() }
}

struct StagingShelfDragPayload {
    let writers: [NSPasteboardWriting]
    let accesses: [FilePreviewAccess]
}

struct StagingShelfPreviewPayload {
    enum Content { case file(URL), text(String) }
    let id: UUID
    let name: String
    let content: Content
    // Keep the original security scope alive until its preview closes.
    let access: FilePreviewAccess?

    /// A view-only adapter for the clipboard detail UI. Never inserted into
    /// history and never used to resolve paths through the history database.
    var previewEntry: ClipboardEntry {
        let kind: ClipboardEntry.Kind
        let text: String?
        let url: URL?
        switch content {
        case .file(let file):
            url = file
            text = nil
            kind = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true ? .image : .fileReference
        case .text(let value):
            url = nil
            text = value
            kind = ClipboardEntry.webURL(from: value) == nil ? .text : .link
        }
        return ClipboardEntry(id: id, createdAt: .now, kind: kind, text: text,
            imageFileName: kind == .image ? url?.lastPathComponent : nil, imagePasteboardType: nil,
            digest: "staging:\(id.uuidString)", byteCount: text?.utf8.count ?? 0, sourceAppName: "暂存箱",
            filePath: url?.path, fileName: url == nil ? nil : name,
            fileType: url.flatMap { UTType(filenameExtension: $0.pathExtension)?.identifier }, recordedAt: [])
    }
}

@MainActor
final class StagingShelfStore {
    nonisolated static let maximumItems = 100
    nonisolated static let maximumOwnedBytes = 128 * 1_024 * 1_024
    nonisolated static let maximumImageBytes = 32 * 1_024 * 1_024
    nonisolated static let maximumTextBytes = 2 * 1_024 * 1_024
    private struct Manifest: Codable { let version: Int; let items: [StagingShelfItem] }

    private(set) var items: [StagingShelfItem] = []
    private(set) var error: String?
    private let directory: URL
    private let assets: URL
    private let manifest: URL
    private let ownedByteLimit: Int
    private var readable = true
    private var liveAccesses: [UUID: FilePreviewAccess] = [:]
    private var exportCleanup: Task<Void, Never>?
    var onChange: (() -> Void)?
    var resolveHistoryAccess: ((URL) -> FilePreviewAccess?)?
    var isHistoryImage: ((URL) -> Bool)?

    init(directory: URL, ownedByteLimit: Int = maximumOwnedBytes) {
        self.directory = directory
        self.ownedByteLimit = max(0, min(ownedByteLimit, Self.maximumOwnedBytes))
        assets = directory.appendingPathComponent("Images", isDirectory: true)
        manifest = directory.appendingPathComponent("items.json")
        do {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                let saved = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
                guard saved.version == 1, saved.items.count <= Self.maximumItems,
                      Set(saved.items.map(\.id)).count == saved.items.count,
                      saved.items.allSatisfy(Self.isValid),
                      saved.items.reduce(0, { $0 + $1.ownedBytes }) <= Self.maximumOwnedBytes else { throw StagingShelfError.unavailable }
                items = saved.items
            }
            cleanupExportedImages()
            scheduleExportCleanup()
        } catch {
            readable = false
            self.error = error.localizedDescription
        }
    }

    private static func isValid(_ item: StagingShelfItem) -> Bool {
        guard item.ownedBytes >= 0 else { return false }
        switch item.kind {
        case .file: return item.filePath?.hasPrefix("/") == true && item.ownedBytes == 0
        case .image: return item.assetName == "\(item.id.uuidString).png" && item.ownedBytes <= maximumImageBytes
        case .text, .link: return item.text != nil && item.ownedBytes == item.text?.utf8.count && item.ownedBytes <= maximumTextBytes
        }
    }

    static func supports(_ board: NSPasteboard) -> Bool {
        board.availableType(from: [.fileURL, .png, .tiff, .URL, .string,
                                   NSPasteboard.PasteboardType("NSFilenamesPboardType")]) != nil
    }

    @discardableResult
    func receive(_ board: NSPasteboard) throws -> Int {
        guard readable else { throw StagingShelfError.unavailable }
        var result = items
        var accesses = liveAccesses
        var written: [URL] = []
        var inserted = 0
        defer { if !written.isEmpty { for url in written { try? FileManager.default.removeItem(at: url) } } }
        func collect(_ incoming: StagingShelfItem, access: FilePreviewAccess? = nil) throws {
            if let existing = result.firstIndex(where: { $0.identity == incoming.identity }) {
                if let access {
                    var refreshed = result[existing]
                    refreshed.bookmark = incoming.bookmark
                    refreshed.bookmarkIsFolder = incoming.bookmarkIsFolder
                    result[existing] = refreshed
                    accesses[refreshed.id] = access
                }
                return
            }
            guard result.count < Self.maximumItems else { throw StagingShelfError.tooManyItems }
            guard result.reduce(0, { $0 + $1.ownedBytes }) + incoming.ownedBytes <= ownedByteLimit else {
                throw StagingShelfError.tooLarge
            }
            result.append(incoming)
            if let access { accesses[incoming.id] = access }
            inserted += 1
        }
        let pasteboardItems = board.pasteboardItems ?? []
        var urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? [])
            .compactMap { $0 as? URL }.filter(\.isFileURL)
        if urls.isEmpty, let paths = board.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        if !urls.isEmpty {
            for url in urls {
                if isHistoryImage?(url) == true {
                    let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    guard size <= Self.maximumImageBytes else { throw StagingShelfError.tooLarge }
                    try collect(try imageItem(Data(contentsOf: url), written: &written))
                } else {
                    guard let access = resolveHistoryAccess?(url) ?? FilePreviewAccess(url: url, usesSecurityScope: true) else {
                        throw StagingShelfError.missingFile(url.lastPathComponent)
                    }
                    let grant = access.bookmarkForTransfer()
                    let item = StagingShelfItem(id: UUID(), kind: .file, name: url.lastPathComponent,
                        createdAt: .now, identity: "file:\(url.standardizedFileURL.path)", filePath: url.path,
                        bookmark: grant?.data, bookmarkIsFolder: grant?.isFolder ?? false, ownedBytes: 0)
                    try collect(item, access: access)
                }
            }
        } else {
            for source in pasteboardItems {
                if let type = source.availableType(from: [.png, .tiff]), let data = source.data(forType: type) {
                    try collect(try imageItem(data, written: &written))
                } else if let string = source.string(forType: .URL) ?? source.string(forType: .string), !string.isEmpty {
                    guard string.utf8.count <= Self.maximumTextBytes else { throw StagingShelfError.tooLarge }
                    let isLink = URL(string: string).map { ["https", "http"].contains($0.scheme?.lowercased() ?? "") } == true
                    let item = StagingShelfItem(id: UUID(), kind: isLink ? .link : .text,
                        name: String(string.prefix(90)).replacingOccurrences(of: "\n", with: " "),
                        createdAt: .now, identity: "text:\(Self.digest(Data(string.utf8)))",
                        text: string, ownedBytes: string.utf8.count)
                    try collect(item)
                } else { throw StagingShelfError.unsupported }
            }
        }
        guard !urls.isEmpty || !pasteboardItems.isEmpty else { throw StagingShelfError.unsupported }
        try persist(result)
        items = result
        liveAccesses = accesses
        let usedAssets = Set(items.compactMap(\.assetName))
        for url in written where !usedAssets.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        written = []
        error = nil
        onChange?()
        return inserted
    }

    private func imageItem(_ data: Data, written: inout [URL]) throws -> StagingShelfItem {
        guard !data.isEmpty, data.count <= Self.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height else { throw StagingShelfError.tooLarge }
        let png: Data
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { png = data }
        else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw StagingShelfError.unsupported }
            let encoded = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
                throw StagingShelfError.unsupported
            }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output), encoded.length <= Self.maximumImageBytes else {
                throw StagingShelfError.tooLarge
            }
            png = encoded as Data
        }
        let identity = "image:\(Self.digest(png))"
        if let existing = items.first(where: { $0.identity == identity }) { return existing }
        let id = UUID()
        let assetName = "\(id.uuidString).png"
        let url = assets.appendingPathComponent(assetName)
        try png.write(to: url, options: .atomic)
        written.append(url)
        return StagingShelfItem(id: id, kind: .image, name: "暂存图片.png", createdAt: .now,
                                identity: identity, assetName: assetName, ownedBytes: png.count)
    }

    func imageURL(for item: StagingShelfItem) -> URL? {
        guard item.kind == .image, item.assetName == "\(item.id.uuidString).png" else { return nil }
        return assets.appendingPathComponent(item.assetName!)
    }

    func fileAccess(for item: StagingShelfItem) -> FilePreviewAccess? {
        if let access = liveAccesses[item.id], FileManager.default.isReadableFile(atPath: access.url.path) { return access }
        guard let path = item.filePath else { return nil }
        let original = URL(fileURLWithPath: path)
        if let bookmark = item.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                       relativeTo: nil, bookmarkDataIsStale: &stale),
               let access = FilePreviewAccess(url: item.bookmarkIsFolder ? original : resolved, usesSecurityScope: true,
                                               containingFolderScope: item.bookmarkIsFolder ? resolved : nil) {
                liveAccesses[item.id] = access
                return access
            }
        }
        let access = resolveHistoryAccess?(original) ?? FilePreviewAccess(url: original, usesSecurityScope: true)
        liveAccesses[item.id] = access
        return access
    }

    func dragPayload(ids: Set<UUID>) throws -> StagingShelfDragPayload {
        let selected = items.filter { ids.contains($0.id) }
        guard !selected.isEmpty, selected.count == ids.count else { throw StagingShelfError.unsupported }
        var writers: [NSPasteboardWriting] = [], accesses: [FilePreviewAccess] = []
        for item in selected {
            switch item.kind {
            case .file:
                guard let access = fileAccess(for: item) else { throw StagingShelfError.missingFile(item.name) }
                writers.append(access.url as NSURL)
                accesses.append(access)
            case .image:
                guard let url = imageURL(for: item), FileManager.default.isReadableFile(atPath: url.path) else {
                    throw StagingShelfError.missingFile(item.name)
                }
                let writer = NSPasteboardItem()
                writer.setString(url.absoluteString, forType: .fileURL)
                writer.setData(try Data(contentsOf: url), forType: .png)
                writers.append(writer)
            case .text, .link:
                let writer = NSPasteboardItem()
                writer.setString(item.text ?? "", forType: .string)
                if item.kind == .link { writer.setString(item.text ?? "", forType: .URL) }
                writers.append(writer)
            }
        }
        return StagingShelfDragPayload(writers: writers, accesses: accesses)
    }

    func previewPayload(id: UUID) throws -> StagingShelfPreviewPayload {
        guard let item = items.first(where: { $0.id == id }) else { throw StagingShelfError.unsupported }
        switch item.kind {
        case .file:
            guard let access = fileAccess(for: item) else { throw StagingShelfError.missingFile(item.name) }
            return StagingShelfPreviewPayload(id: id, name: item.name, content: .file(access.url), access: access)
        case .image:
            guard let url = imageURL(for: item), FileManager.default.isReadableFile(atPath: url.path) else {
                throw StagingShelfError.missingFile(item.name)
            }
            return StagingShelfPreviewPayload(id: id, name: item.name, content: .file(url), access: nil)
        case .text, .link:
            return StagingShelfPreviewPayload(id: id, name: item.name, content: .text(item.text ?? ""), access: nil)
        }
    }

    func remove(_ ids: Set<UUID>, afterSuccessfulExport: Bool = false) throws {
        guard readable else { throw StagingShelfError.unavailable }
        let removed = items.filter { ids.contains($0.id) }
        let kept = items.filter { !ids.contains($0.id) }
        if afterSuccessfulExport {
            // Targets may open a dropped file URL asynchronously. Keep only
            // our small owned image assets alive for a short delivery grace;
            // original files are never copied, moved or deleted.
            for item in removed {
                if let url = imageURL(for: item) {
                    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                }
            }
        }
        try persist(kept)
        items = kept
        for item in removed {
            liveAccesses[item.id] = nil
            if !afterSuccessfulExport, let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
        }
        if afterSuccessfulExport { cleanupExportedImages(); scheduleExportCleanup() }
        error = nil
        onChange?()
    }

    func editText(id: UUID, text: String) throws {
        guard readable, let index = items.firstIndex(where: { $0.id == id }),
              items[index].kind == .text || items[index].kind == .link else { throw StagingShelfError.unavailable }
        guard text.utf8.count <= Self.maximumTextBytes,
              items.reduce(0, { $0 + $1.ownedBytes }) - items[index].ownedBytes + text.utf8.count <= ownedByteLimit else {
            throw StagingShelfError.tooLarge
        }
        let identity = "text:\(Self.digest(Data(text.utf8)))"
        guard !items.contains(where: { $0.id != id && $0.identity == identity }) else { throw StagingShelfError.duplicateText }
        var updated = items
        updated[index] = StagingShelfItem(id: id, kind: ClipboardEntry.webURL(from: text) == nil ? .text : .link,
            name: String(text.prefix(90)).replacingOccurrences(of: "\n", with: " "),
            createdAt: items[index].createdAt, identity: identity, text: text, ownedBytes: text.utf8.count)
        try persist(updated)
        items = updated
        onChange?()
    }

    func cleanupExportedImages(now: Date = .now) {
        guard readable else { return }
        let used = Set(items.compactMap(\.assetName))
        let files = (try? FileManager.default.contentsOfDirectory(at: assets,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where !used.contains(url.lastPathComponent) && url.pathExtension == "png"
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(modified) >= 60 { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func scheduleExportCleanup() {
        exportCleanup?.cancel()
        exportCleanup = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(61))
            guard !Task.isCancelled else { return }
            self?.cleanupExportedImages()
            self?.exportCleanup = nil
        }
    }

    deinit { exportCleanup?.cancel() }

    private func persist(_ items: [StagingShelfItem]) throws {
        let data = try JSONEncoder().encode(Manifest(version: 1, items: items))
        try data.write(to: manifest, options: .atomic)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
