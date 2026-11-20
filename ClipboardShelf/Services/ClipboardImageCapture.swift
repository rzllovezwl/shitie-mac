import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ClipboardImagePayload {
    let data: Data
    let type: String
}

enum ImageFileExport {
    private static let lastDirectoryKey = "lastImageExportDirectory"

    @MainActor
    static func makePanel(name: String, type: UTType = .png,
                          defaults: UserDefaults = .standard) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = "保存图片"
        panel.prompt = "保存"
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.directoryURL = defaults.string(forKey: lastDirectoryKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if URL(fileURLWithPath: name).pathExtension.isEmpty,
           let suffix = type.preferredFilenameExtension {
            panel.nameFieldStringValue = "\(name).\(suffix)"
        } else {
            panel.nameFieldStringValue = name
        }
        return panel
    }

    @MainActor
    static func destination(in panel: NSSavePanel, response: NSApplication.ModalResponse,
                            defaults: UserDefaults = .standard) -> URL? {
        guard response == .OK, let url = panel.url else { return nil }
        defaults.set(url.deletingLastPathComponent().path, forKey: lastDirectoryKey)
        return url
    }

    static func suggestedName(_ title: String, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "\(title) \(formatter.string(from: date))"
    }

    static func write(_ data: Data, to url: URL) throws {
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }
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

enum ImageOCRError: LocalizedError {
    case unreadableImage
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "无法读取这张图片，请确认原文件仍可访问。"
        case .timedOut: "识别超时，请重试。"
        }
    }
}

struct ImageOCRLine: Sendable {
    let text: String
    /// Pixel coordinates measured from the image's upper-left corner.
    let rect: CGRect
}

enum ImageOCRService {
    private actor Preparation {
        private var task: Task<Void, Never>?

        func sharedTask() -> Task<Void, Never> {
            if let task { return task }
            let newTask = Task.detached(priority: .utility) {
                warmUpSynchronously()
            }
            task = newTask
            return newTask
        }
    }

    private static let preparation = Preparation()

    private final class CompletionGate<Output: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Output, Error>?
        private var result: Result<Output, Error>?

        func wait() async throws -> Output {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func finish(_ result: Result<Output, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private final class RequestCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var request: VNRequest?
        private var isCancelled = false

        func install(_ request: VNRequest) {
            lock.lock()
            let cancelled = isCancelled
            if !cancelled { self.request = request }
            lock.unlock()
            if cancelled { request.cancel() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let request = self.request
            lock.unlock()
            request?.cancel()
        }
    }

    private struct Line {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let tile: Int

        var result: ImageOCRLine {
            ImageOCRLine(text: text, rect: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    static func prepareInBackground() {
        Task.detached(priority: .utility) { await prepare() }
    }

    private static func prepare() async {
        let task = await preparation.sharedTask()
        await task.value
    }

    private static func warmUpSynchronously() {
        guard let context = CGContext(
            data: nil, width: 256, height: 96, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 96))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for x in stride(from: 24, through: 200, by: 32) {
            context.fill(CGRect(x: x, y: 24, width: 17, height: 44))
        }
        guard let image = context.makeImage() else { return }
        // Preparation is best effort. A failure must not block a real request.
        try? VNImageRequestHandler(cgImage: image).perform([makeRequest()])
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let preferred = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        return request
    }

    static func recognize(at url: URL, timeout: Duration = .seconds(90),
                          priority: TaskPriority = .userInitiated) async throws -> String {
        try await recognize(timeout: timeout, priority: priority) { cancellation in
            try recognizeSynchronously(at: url, cancellation: cancellation)
        }
    }

    /// A screenshot being edited has no history file yet. Read its in-memory
    /// pixels directly so OCR does not create a temporary copy or a card.
    static func recognize(_ image: CGImage,
                          timeout: Duration = .seconds(90)) async throws -> String {
        try await recognize(timeout: timeout) { cancellation in
            try recognizeSynchronously(image: image, cancellation: cancellation)
                .map(\.text).joined(separator: "\n")
        }
    }

    /// Keeps Vision's line boxes so translations can be placed over the
    /// corresponding words without creating an intermediate history card.
    static func recognizeLines(_ image: CGImage,
                               timeout: Duration = .seconds(90)) async throws -> [ImageOCRLine] {
        try await recognize(timeout: timeout) { cancellation in
            try recognizeSynchronously(image: image, cancellation: cancellation)
        }
    }

    private static func recognize<Output: Sendable>(
        timeout: Duration, priority: TaskPriority = .userInitiated,
        work recognizeImage: @escaping (RequestCancellation) throws -> Output
    ) async throws -> Output {
        let cancellation = RequestCancellation()
        let completion = CompletionGate<Output>()
        let work = Task.detached(priority: priority) {
            do {
                await prepare()
                try Task<Never, Never>.checkCancellation()
                let text = try recognizeImage(cancellation)
                completion.finish(.success(text))
            } catch {
                completion.finish(.failure(error))
            }
        }
        let deadline = Task.detached {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            completion.finish(.failure(ImageOCRError.timedOut))
            cancellation.cancel()
            work.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await completion.wait()
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            cancellation.cancel()
            work.cancel()
        }
    }

    private static func recognizeSynchronously(
        at url: URL, cancellation: RequestCancellation
    ) throws -> String {
        try Task<Never, Never>.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ImageOCRError.unreadableImage
        }
        let width = sourceWidth.doubleValue
        let height = sourceHeight.doubleValue
        guard width > 0, height > 0 else { throw ImageOCRError.unreadableImage }
        // Keep ordinary phone screenshots at source resolution. Bound unusually
        // large images before decoding; long images are then read in tiles.
        let longest = max(width, height)
        let areaScale = sqrt(24_000_000 / (width * height))
        let edgeScale = 16_384 / longest
        let scale = min(1, areaScale, edgeScale)
        let maximumDimension = max(1, Int(ceil(longest * scale)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ] as CFDictionary) else { throw ImageOCRError.unreadableImage }

        return try recognizeSynchronously(image: image, cancellation: cancellation)
            .map(\.text).joined(separator: "\n")
    }

    private static func recognizeSynchronously(
        image: CGImage, cancellation: RequestCancellation
    ) throws -> [ImageOCRLine] {
        let request = makeRequest()
        cancellation.install(request)

        var lines: [Line] = []
        var tileIndex = 0
        for y in tileStarts(length: image.height) {
            for x in tileStarts(length: image.width) {
                try Task<Never, Never>.checkCancellation()
                let rect = CGRect(x: x, y: y,
                                  width: min(4096, image.width - x),
                                  height: min(4096, image.height - y))
                guard let tile = image.cropping(to: rect) else { continue }
                try VNImageRequestHandler(cgImage: tile).perform([request])
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let line = Line(
                        text: text,
                        x: CGFloat(x) + observation.boundingBox.minX * rect.width,
                        y: CGFloat(y) + (1 - observation.boundingBox.maxY) * rect.height,
                        width: observation.boundingBox.width * rect.width,
                        height: observation.boundingBox.height * rect.height,
                        tile: tileIndex
                    )
                    // Adjacent tiles overlap so a line crossing a boundary is
                    // not lost. Discard the second reading of the same line.
                    if !lines.contains(where: {
                        $0.tile != line.tile && $0.text == line.text &&
                            abs($0.x - line.x) < 24 && abs($0.y - line.y) < 24
                    }) {
                        lines.append(line)
                    }
                }
                tileIndex += 1
            }
        }
        return lines.sorted {
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.x < $1.x
        }.map(\.result)
    }

    private static func tileStarts(length: Int) -> [Int] {
        guard length > 4096 else { return [0] }
        var starts = Array(stride(from: 0, through: length - 4096, by: 3968))
        let last = length - 4096
        if starts.last != last { starts.append(last) }
        return starts
    }
}
