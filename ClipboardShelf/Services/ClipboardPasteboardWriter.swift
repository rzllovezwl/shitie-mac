import AppKit

/// Keeps security-scoped originals open until an external drag ends.
struct ClipboardDragPayload {
    let writers: [NSPasteboardWriting]
    let fileAccesses: [FilePreviewAccess]
}

enum ClipboardCopyFormat: String, CaseIterable, Identifiable {
    static let preferenceKey = "defaultCopyFormat"

    case original, plainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "原格式"
        case .plainText: "纯文本"
        }
    }

    @MainActor
    func mode(for entry: ClipboardEntry) -> ClipboardPasteboardWriter.Mode {
        self == .plainText && (entry.kind == .text || entry.kind == .link)
            ? .plainText : .original
    }
}

enum ClipboardGroupingPreference {
    static let key = "automaticallyGroupMultipleCopies"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

@MainActor
enum ClipboardPasteboardWriter {
    enum Mode: Equatable { case original, plainText }

    /// Build an independent drag pasteboard without replacing the user's
    /// general clipboard or counting the operation as a new copy.
    static func dragPayload(
        _ entries: [ClipboardEntry], from store: ClipboardHistoryStore
    ) -> ClipboardDragPayload? {
        let members = entries.flatMap { $0.kind == .group ? $0.groupMembers : [$0] }
        guard !members.isEmpty,
              !members.contains(where: { $0.kind == .unavailableImage }) else { return nil }

        if members.count > 1 && members.allSatisfy({ $0.kind == .text || $0.kind == .link }) {
            let texts = members.compactMap(\.text)
            guard texts.count == members.count else { return nil }
            let item = NSPasteboardItem()
            guard item.setString(texts.joined(separator: "\n\n"), forType: .string) else { return nil }
            return ClipboardDragPayload(writers: [item], fileAccesses: [])
        }

        var writers: [NSPasteboardWriting] = []
        var fileAccesses: [FilePreviewAccess] = []
        for entry in members {
            switch entry.kind {
            case .text, .link:
                guard let text = entry.text else { return nil }
                let item = NSPasteboardItem()
                guard item.setString(text, forType: .string) else { return nil }
                if entry.hasRichText {
                    let rich = store.richTextData(for: entry)
                    if let rtf = rich.rtf, !item.setData(rtf, forType: .rtf) { return nil }
                    if let html = rich.html, !item.setData(html, forType: .html) { return nil }
                    if let rtfd = rich.rtfd, !item.setData(rtfd, forType: .rtfd) { return nil }
                }
                writers.append(item)
            case .image:
                guard let url = store.imageURL(for: entry),
                      let data = try? Data(contentsOf: url) else { return nil }
                let item = NSPasteboardItem()
                guard item.setString(url.absoluteString, forType: .fileURL),
                      item.setData(
                        data, forType: NSPasteboard.PasteboardType(entry.imagePasteboardType ?? "public.png")
                      ) else { return nil }
                writers.append(item)
            case .fileReference:
                guard let access = store.filePreviewAccess(for: entry) else { return nil }
                fileAccesses.append(access)
                writers.append(access.url as NSURL)
            case .unavailableImage, .group:
                return nil
            }
        }
        return ClipboardDragPayload(writers: writers, fileAccesses: fileAccesses)
    }

    static func write(
        _ entry: ClipboardEntry,
        from store: ClipboardHistoryStore,
        to board: NSPasteboard,
        mode: Mode = .original
    ) -> Bool {
        if mode == .plainText && entry.kind != .text && entry.kind != .link {
            return false
        }
        switch entry.kind {
        case .text, .link:
            guard let text = entry.text else { return false }
            if entry.hasRichText && mode == .original {
                let formats = store.richTextData(for: entry)
                let item = NSPasteboardItem()
                guard item.setString(text, forType: .string) else { return false }
                if let rtf = formats.rtf, !item.setData(rtf, forType: .rtf) { return false }
                if let html = formats.html, !item.setData(html, forType: .html) { return false }
                if let rtfd = formats.rtfd, !item.setData(rtfd, forType: .rtfd) { return false }
                board.clearContents()
                return board.writeObjects([item])
            }
            board.clearContents()
            return board.setString(text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: entry),
                  let data = try? Data(contentsOf: url) else { return false }
            let item = NSPasteboardItem()
            guard item.setData(data, forType: NSPasteboard.PasteboardType(entry.imagePasteboardType ?? "public.png")) else {
                return false
            }
            board.clearContents()
            return board.writeObjects([item])
        case .unavailableImage:
            return false
        case .fileReference:
            return store.withUsableFileURL(for: entry) { url in
                board.clearContents()
                return board.writeObjects([url as NSURL])
            } ?? false
        case .group:
            return write(entry.groupMembers, from: store, to: board, mode: mode)
        }
    }

    /// Prepare every representation before replacing the user's clipboard.
    static func write(
        _ entries: [ClipboardEntry], from store: ClipboardHistoryStore,
        to board: NSPasteboard, mode: Mode = .original
    ) -> Bool {
        let members = entries.flatMap { $0.kind == .group ? $0.groupMembers : [$0] }
        guard !members.isEmpty else { return false }
        guard !members.contains(where: { $0.kind == .unavailableImage }) else { return false }
        if members.count == 1 { return write(members[0], from: store, to: board, mode: mode) }

        if members.allSatisfy({ $0.kind == .text || $0.kind == .link }) {
            let texts = members.compactMap(\.text)
            guard texts.count == members.count else { return false }
            board.clearContents()
            return board.setString(texts.joined(separator: "\n\n"), forType: .string)
        }
        if members.allSatisfy({ $0.kind == .fileReference }) {
            let urls = members.compactMap { store.withUsableFileURL(for: $0) { $0 as NSURL } }
            guard urls.count == members.count else { return false }
            board.clearContents()
            return board.writeObjects(urls)
        }

        let allImages = members.allSatisfy { $0.kind == .image }
        var items: [NSPasteboardItem] = []
        for entry in members {
            let item = NSPasteboardItem()
            switch entry.kind {
            case .text, .link:
                guard let text = entry.text, item.setString(text, forType: .string) else { return false }
                if entry.hasRichText && mode == .original {
                    let rich = store.richTextData(for: entry)
                    if let rtf = rich.rtf, !item.setData(rtf, forType: .rtf) { return false }
                    if let html = rich.html, !item.setData(html, forType: .html) { return false }
                    if let rtfd = rich.rtfd, !item.setData(rtfd, forType: .rtfd) { return false }
                }
            case .image:
                guard let url = store.imageURL(for: entry),
                      let data = try? Data(contentsOf: url) else { return false }
                // Many destinations import a collection of files but inspect
                // only the first raw image item. Offer each saved image as a
                // file URL as well, while retaining its pixel representation.
                if allImages && !item.setString(url.absoluteString, forType: .fileURL) {
                    return false
                }
                guard
                      item.setData(data, forType: NSPasteboard.PasteboardType(entry.imagePasteboardType ?? "public.png")) else {
                    return false
                }
            case .unavailableImage:
                return false
            case .fileReference:
                guard let url = store.withUsableFileURL(for: entry, { $0 }),
                      item.setString(url.absoluteString, forType: .fileURL) else { return false }
            case .group:
                return false
            }
            items.append(item)
        }
        board.clearContents()
        return board.writeObjects(items)
    }
}
