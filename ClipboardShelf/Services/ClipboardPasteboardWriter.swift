import AppKit

@MainActor
enum ClipboardPasteboardWriter {
    enum Mode { case original, plainText }

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
        case .fileReference:
            return store.withUsableFileURL(for: entry) { url in
                board.clearContents()
                return board.writeObjects([url as NSURL])
            } ?? false
        }
    }
}
