import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ClipboardImagePayload {
    let data: Data
    let type: String
}

/// Chat apps can advertise a short-lived image file URL alongside image data.
/// Capture its pixels while the pasteboard still owns the URL; Finder file
/// copies remain file references with their original file semantics.
enum ClipboardImageCapture {
    private static let supportedTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .gif]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "webp", "bmp"
    ]

    static func capture(
        items: [NSPasteboardItem], fileURLs: [URL],
        sourceAppName: String?, sourceAppBundleID: String?,
        maximumBytes: Int
    ) -> ClipboardImagePayload? {
        let chatImage = isWeChatImageReference(
            fileURLs: fileURLs, sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
        guard fileURLs.isEmpty || chatImage else { return nil }

        for item in items {
            // WeChat can attach an encoded image to a private pasteboard type
            // instead of advertising public.jpeg/public.tiff. Inspect each
            // item's image-like representations before treating it as metadata.
            for pasteboardType in item.types where isImageRepresentation(
                pasteboardType, fromWeChat: isWeChatSource(
                    name: sourceAppName, bundleID: sourceAppBundleID
                )
            ) {
                guard let data = item.data(forType: pasteboardType),
                      let payload = validated(data, maximumBytes: maximumBytes) else { continue }
                return payload
            }
        }

        guard chatImage else { return nil }
        return captureFile(at: fileURLs[0], maximumBytes: maximumBytes)
    }

    static func isWeChatImageReference(
        fileURLs: [URL], sourceAppName: String?, sourceAppBundleID: String?
    ) -> Bool {
        guard fileURLs.count == 1 else { return false }
        let fileURL = fileURLs[0]
        guard isImageFileURL(fileURL) else { return false }
        return isWeChat(name: sourceAppName, bundleID: sourceAppBundleID, fileURL: fileURL)
    }

    static func isImageFileURL(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.localizedLowercase)
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    static func isWeChatSource(name: String?, bundleID: String?) -> Bool {
        [name, bundleID].compactMap { $0?.localizedLowercase }
            .contains { $0.contains("微信") || $0.contains("wechat") || $0.contains("weixin") }
    }

    /// A denied container may make `fileExists` return false as well as deny
    /// reading. Detect the location without probing it, so the rest of a
    /// WeChat multi-selection can still be recorded immediately.
    static func isAppDataContainerURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return url.isFileURL && (path.contains("/Library/Containers/")
            || path.contains("/Library/Group Containers/"))
    }

    private static func captureFile(at url: URL, maximumBytes: Int) -> ClipboardImagePayload? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maximumBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return validated(data, maximumBytes: maximumBytes)
    }

    private static func validated(_ data: Data, maximumBytes: Int) -> ClipboardImagePayload? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String? else { return nil }
        if supportedTypes.contains(where: { $0.identifier == identifier }) {
            return ClipboardImagePayload(data: data, type: identifier)
        }
        // Normalize other formats supported by ImageIO, such as WebP, so the
        // history store has a reliable extension and can copy the pixels back.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = NSBitmapImageRep(cgImage: image).representation(
                  using: .png, properties: [:]
              ), png.count <= maximumBytes else { return nil }
        return ClipboardImagePayload(data: png, type: UTType.png.identifier)
    }

    private static func isImageRepresentation(
        _ type: NSPasteboard.PasteboardType, fromWeChat: Bool
    ) -> Bool {
        if isKnownImageRepresentation(type) { return true }
        let identifier = type.rawValue.localizedLowercase
        return identifier.contains("image") || identifier.contains("picture")
            || identifier.contains("photo")
            || (fromWeChat && identifier.contains("tencent"))
    }

    static func isKnownImageRepresentation(_ type: NSPasteboard.PasteboardType) -> Bool {
        supportedTypes.contains { $0.identifier == type.rawValue }
            || UTType(type.rawValue)?.conforms(to: .image) == true
    }

    private static func isWeChat(name: String?, bundleID: String?, fileURL: URL) -> Bool {
        if isWeChatSource(name: name, bundleID: bundleID) { return true }
        // The foreground app can change before our 0.6-second pasteboard poll.
        // The source application's cache path still identifies its image.
        let path = fileURL.path.localizedLowercase
        return path.contains("/wechat/") || path.contains("/weixin/")
            || path.contains("/com.tencent.xinwechat/")
    }
}
