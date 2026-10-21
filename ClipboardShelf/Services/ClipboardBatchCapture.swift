import AppKit
import UniformTypeIdentifiers

enum ClipboardCapturedItem {
    case text(String)
    case richText(String, rtf: Data?, html: Data?, rtfd: Data?)
    case image(Data, type: String)
    /// The source exposed a temporary image URL but macOS did not allow us to
    /// read image bytes. This is metadata only and must never be pasted as an image.
    case unavailableImage(URL)
    case fileReference(URL)
}

enum ClipboardBatchCaptureError: LocalizedError {
    case oversizedText
    case incompleteBatch
    case unavailableChatImage

    var errorDescription: String? {
        switch self {
        case .oversizedText:
            "这次复制的文字超过 32 MB，未加入历史；系统剪贴板中的内容仍可粘贴。"
        case .incompleteBatch:
            "这次复制包含无法记录的项目，未保存不完整的分组；系统剪贴板内容仍可粘贴。"
        case .unavailableChatImage:
            "这次微信图片未能保存：图片无法读取或超过 15 MB，请重新复制。"
        }
    }
}

/// One pasteboard change is one capture boundary. Alternate representations
/// on an NSPasteboardItem are one logical item, except when a chat app supplies
/// a distinct message text alongside its image. Parsing finishes before
/// history is modified.
enum ClipboardBatchCapture {
    private static let weChatMultiSelectionType = NSPasteboard.PasteboardType(
        "com.trolltech.anymime.x-xwechat-multiselect-copy"
    )

    static func isWeChatMultiSelection(_ board: NSPasteboard) -> Bool {
        board.pasteboardItems?.contains {
            $0.types.contains(weChatMultiSelectionType)
        } == true
    }

    static func capture(
        from board: NSPasteboard,
        sourceAppName: String?, sourceAppBundleID: String?,
        maximumImageBytes: Int, maximumTextBytes: Int,
        maximumRichTextBytes: Int,
        allowUnavailableImagePlaceholder: Bool = false
    ) throws -> [ClipboardCapturedItem] {
        let items = board.pasteboardItems ?? []
        if let selectedMessages = try captureWeChatMultiSelection(
            items, from: board, maximumImageBytes: maximumImageBytes,
            maximumTextBytes: maximumTextBytes,
            allowUnavailableImagePlaceholder: allowUnavailableImagePlaceholder
        ) {
            return selectedMessages
        }
        let fileURLs = (board.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) ?? []).compactMap { $0 as? URL }.filter(\.isFileURL)
        if !fileURLs.isEmpty {
            let fileOnly = items.isEmpty || items.allSatisfy { item in
                if let url = fileURL(from: item) {
                    // A chat message can put its image URL and a distinct
                    // copied text message on one pasteboard item.
                    return !isChatImage(url, sourceAppName: sourceAppName,
                                        sourceAppBundleID: sourceAppBundleID)
                        || additionalText(in: item, imageURL: url,
                                          maximumRichTextBytes: maximumRichTextBytes) == nil
                }
                return !advertisesUserContent(item) && !hasPrivateImageType(item)
            }
            if fileOnly {
                var seen: Set<String> = []
                return try fileURLs.compactMap { url in
                    let normalized = url.standardizedFileURL
                    guard seen.insert(normalized.path).inserted else { return nil }
                    guard isChatImage(normalized, sourceAppName: sourceAppName,
                                      sourceAppBundleID: sourceAppBundleID) else {
                        return .fileReference(normalized)
                    }
                    let matchingItems = items.filter {
                        fileURL(from: $0)?.standardizedFileURL == normalized
                    }
                    guard let image = ClipboardImageCapture.capture(
                        items: matchingItems.isEmpty && fileURLs.count == 1 ? items : matchingItems,
                        fileURLs: [normalized], sourceAppName: sourceAppName,
                        sourceAppBundleID: sourceAppBundleID, maximumBytes: maximumImageBytes
                    ) else {
                        return try unavailableImage(
                            at: normalized, allowPlaceholder: allowUnavailableImagePlaceholder
                        )
                    }
                    return .image(image.data, type: image.type)
                }
            }
        }

        var captured: [ClipboardCapturedItem] = []
        var capturedFilePaths: Set<String> = []
        let unclaimedChatURLs = fileURLs.filter {
            isChatImage($0, sourceAppName: sourceAppName,
                        sourceAppBundleID: sourceAppBundleID)
        }
        for item in items {
            if let url = fileURL(from: item) {
                let normalized = url.standardizedFileURL
                if capturedFilePaths.insert(normalized.path).inserted {
                    if isChatImage(normalized, sourceAppName: sourceAppName,
                                   sourceAppBundleID: sourceAppBundleID) {
                        if let image = ClipboardImageCapture.capture(
                            items: [item], fileURLs: [normalized],
                            sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID,
                            maximumBytes: maximumImageBytes
                        ) {
                            captured.append(.image(image.data, type: image.type))
                        } else {
                            captured.append(try unavailableImage(
                                at: normalized, allowPlaceholder: allowUnavailableImagePlaceholder
                            ))
                        }
                        if let text = additionalText(
                            in: item, imageURL: normalized,
                            maximumRichTextBytes: maximumRichTextBytes
                        ) {
                            guard text.utf8.count <= maximumTextBytes else {
                                throw ClipboardBatchCaptureError.oversizedText
                            }
                            captured.append(.text(text))
                        }
                    } else {
                        captured.append(.fileReference(normalized))
                    }
                }
                continue
            }
            let itemCouldBeImage = item.types.contains {
                ClipboardImageCapture.isKnownImageRepresentation($0)
            } || (item.string(forType: .string) == nil &&
                  !item.types.contains(where: { $0 == .rtf || $0 == .html || $0 == .rtfd }))
            let associatedChatURL = itemCouldBeImage
                ? unclaimedChatURLs.first { !capturedFilePaths.contains($0.standardizedFileURL.path) }
                : nil
            if let image = ClipboardImageCapture.capture(
                items: [item], fileURLs: associatedChatURL.map { [$0] } ?? [],
                sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID,
                maximumBytes: maximumImageBytes
            ) {
                captured.append(.image(image.data, type: image.type))
                if let associatedChatURL {
                    capturedFilePaths.insert(associatedChatURL.standardizedFileURL.path)
                }
                if let text = additionalText(
                    in: item, imageURL: associatedChatURL,
                    maximumRichTextBytes: maximumRichTextBytes
                ),
                   associatedChatURL != nil || ClipboardImageCapture.isWeChatSource(
                       name: sourceAppName, bundleID: sourceAppBundleID
                   ) {
                    guard text.utf8.count <= maximumTextBytes else {
                        throw ClipboardBatchCaptureError.oversizedText
                    }
                    captured.append(.text(text))
                }
                continue
            }
            let directText = item.string(forType: .string)
            let byteCount = directText?.utf8.count
            if let byteCount, byteCount > maximumTextBytes {
                throw ClipboardBatchCaptureError.oversizedText
            }
            // Large plain text should not materialize equally large rich data.
            let readRich = byteCount.map { $0 <= maximumRichTextBytes } ?? true
            let rtf = readRich ? item.data(forType: .rtf) : nil
            let html = readRich ? item.data(forType: .html) : nil
            let rtfd = readRich ? item.data(forType: .rtfd) : nil
            let text = directText
                ?? plainText(from: rtf, type: .rtf, maximumBytes: maximumRichTextBytes)
                ?? plainText(from: html, type: .html, maximumBytes: maximumRichTextBytes)
                ?? plainText(from: rtfd, type: .rtfd, maximumBytes: maximumRichTextBytes)
            guard let text, !text.isEmpty else {
                // Multi-message copies may include an extra WeChat metadata
                // item. It has no image, file or text to show on the shelf and
                // must not make the actual messages roll back together.
                if items.count > 1 && advertisesUserContent(item) {
                    throw ClipboardBatchCaptureError.incompleteBatch
                }
                continue
            }
            guard text.utf8.count <= maximumTextBytes else {
                throw ClipboardBatchCaptureError.oversizedText
            }
            if rtf != nil || html != nil || rtfd != nil {
                captured.append(.richText(text, rtf: rtf, html: html, rtfd: rtfd))
            } else {
                captured.append(.text(text))
            }
        }
        // Some providers expose their temporary image URL through
        // readObjects but leave it off the individual pasteboard items.
        // Preserve that image alongside the text instead of rejecting the
        // whole copied selection as an incomplete batch.
        let missingChatURLs = fileURLs.filter {
            let path = $0.standardizedFileURL.path
            return !capturedFilePaths.contains(path) &&
                isChatImage($0, sourceAppName: sourceAppName,
                            sourceAppBundleID: sourceAppBundleID)
        }
        for url in missingChatURLs.reversed() {
            if let image = ClipboardImageCapture.capture(
                items: [], fileURLs: [url], sourceAppName: sourceAppName,
                sourceAppBundleID: sourceAppBundleID, maximumBytes: maximumImageBytes
            ) {
                captured.insert(.image(image.data, type: image.type), at: 0)
            } else {
                captured.insert(try unavailableImage(
                    at: url, allowPlaceholder: allowUnavailableImagePlaceholder
                ), at: 0)
            }
            capturedFilePaths.insert(url.standardizedFileURL.path)
        }
        let expectedFiles = Set(fileURLs.map { $0.standardizedFileURL.path })
        guard expectedFiles.isSubset(of: capturedFilePaths) else {
            throw ClipboardBatchCaptureError.incompleteBatch
        }
        return captured
    }

    /// WeChat's multi-select copy carries an ordered JSON array of messages
    /// in a private pasteboard type. Public file URLs can cover only part of
    /// that array, so the message list determines the complete item order.
    private static func captureWeChatMultiSelection(
        _ items: [NSPasteboardItem], from board: NSPasteboard,
        maximumImageBytes: Int,
        maximumTextBytes: Int,
        allowUnavailableImagePlaceholder: Bool
    ) throws -> [ClipboardCapturedItem]? {
        guard let item = items.first(where: { $0.types.contains(weChatMultiSelectionType) }) else {
            return nil
        }
        guard let data = item.data(forType: weChatMultiSelectionType),
              data.count <= maximumTextBytes,
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !messages.isEmpty else { throw ClipboardBatchCaptureError.incompleteBatch }

        // Keep the URLs supplied by the pasteboard. Reconstructing a URL from
        // WeChat's JSON path can discard the pasteboard's file access grant.
        let publicURLs = (board.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) ?? []).compactMap { $0 as? URL }.filter(\.isFileURL)
        let urlsByPath = Dictionary(publicURLs.map { ($0.standardizedFileURL.path, $0) },
                                   uniquingKeysWith: { first, _ in first })

        var captured: [ClipboardCapturedItem] = []
        for message in messages {
            if let path = message["file"] as? String, !path.isEmpty {
                let parsedURL: URL?
                if path.hasPrefix("/") {
                    parsedURL = URL(fileURLWithPath: path).standardizedFileURL
                } else if let parsed = URL(string: path), parsed.isFileURL {
                    parsedURL = parsed.standardizedFileURL
                } else {
                    parsedURL = nil
                }
                guard let parsedURL else { throw ClipboardBatchCaptureError.incompleteBatch }
                let url = urlsByPath[parsedURL.path] ?? parsedURL
                if ClipboardImageCapture.isImageFileURL(url) {
                    let matchingItems = items.filter {
                        fileURL(from: $0)?.standardizedFileURL.path == parsedURL.path
                    }
                    if let image = ClipboardImageCapture.capture(
                        items: matchingItems, fileURLs: [url], sourceAppName: "微信",
                        sourceAppBundleID: "com.tencent.xinWeChat",
                        maximumBytes: maximumImageBytes
                    ) {
                        captured.append(.image(image.data, type: image.type))
                    } else {
                        captured.append(try unavailableImage(
                            at: url, allowPlaceholder: allowUnavailableImagePlaceholder
                        ))
                    }
                } else {
                    captured.append(.fileReference(url))
                }
            } else if let text = message["text"] as? String, !text.isEmpty {
                guard text.utf8.count <= maximumTextBytes else {
                    throw ClipboardBatchCaptureError.oversizedText
                }
                captured.append(.text(text))
            } else {
                throw ClipboardBatchCaptureError.incompleteBatch
            }
        }
        return captured
    }

    private static func fileURL(from item: NSPasteboardItem) -> URL? {
        guard let value = item.string(forType: .fileURL),
              let url = URL(string: value), url.isFileURL else { return nil }
        return url
    }

    private static func unavailableImage(
        at url: URL, allowPlaceholder: Bool
    ) throws -> ClipboardCapturedItem {
        // A protected app container cannot be recovered by repeatedly polling
        // the same pasteboard change. Keep the rest of that copy immediately.
        // Other temporary URLs get the normal short retry window first.
        if allowPlaceholder || ClipboardImageCapture.isAppDataContainerURL(url) {
            return .unavailableImage(url)
        }
        throw ClipboardBatchCaptureError.unavailableChatImage
    }

    private static func isChatImage(
        _ url: URL, sourceAppName: String?, sourceAppBundleID: String?
    ) -> Bool {
        ClipboardImageCapture.isWeChatImageReference(
            fileURLs: [url], sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
    }

    private static func additionalText(
        in item: NSPasteboardItem, imageURL: URL?, maximumRichTextBytes: Int
    ) -> String? {
        let original = item.string(forType: .string)
            ?? plainText(from: item.data(forType: .rtf), type: .rtf,
                         maximumBytes: maximumRichTextBytes)
            ?? plainText(from: item.data(forType: .html), type: .html,
                         maximumBytes: maximumRichTextBytes)
            ?? plainText(from: item.data(forType: .rtfd), type: .rtfd,
                         maximumBytes: maximumRichTextBytes)
        guard let original else { return nil }
        let text = original.replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let imageURL, [imageURL.absoluteString, imageURL.path,
                          imageURL.lastPathComponent].contains(text) { return nil }
        return original
    }

    private static func advertisesUserContent(_ item: NSPasteboardItem) -> Bool {
        item.types.contains { type in
            if type == .fileURL || type == .string || type == .rtf
                || type == .html || type == .rtfd { return true }
            return ClipboardImageCapture.isKnownImageRepresentation(type)
        }
    }

    private static func hasPrivateImageType(_ item: NSPasteboardItem) -> Bool {
        item.types.contains { type in
            let name = type.rawValue.localizedLowercase
            return name.contains("image") || name.contains("picture")
                || name.contains("photo")
        }
    }

    private static func plainText(
        from data: Data?, type: NSAttributedString.DocumentType, maximumBytes: Int
    ) -> String? {
        guard let data, data.count <= maximumBytes else { return nil }
        return try? NSAttributedString(
            data: data, options: [.documentType: type], documentAttributes: nil
        ).string
    }
}
