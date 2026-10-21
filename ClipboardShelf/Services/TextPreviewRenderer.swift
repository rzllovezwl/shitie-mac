import AppKit
import Foundation
import ImageIO

struct RichTextSourceFiles: Equatable {
    let rtf: URL?
    let html: URL?
    let rtfd: URL?
}

enum TextPreviewMode: String, CaseIterable, Identifiable {
    case original = "原格式"
    case plain = "原文"
    case markdown = "Markdown"
    case code = "代码"

    var id: String { rawValue }

    static func suggested(for classification: ClipboardTextClassification, hasRichText: Bool) -> Self {
        if classification == .markdown { return .markdown }
        // Editors can include RTF alongside code. Show the detected syntax by
        // default while keeping the original format available in details.
        if classification.codeLanguage != nil { return .code }
        if hasRichText { return .original }
        return .plain
    }

    func renderingMode(for classification: ClipboardTextClassification, hasRichText: Bool) -> Self {
        guard self == .original else { return self }
        // For Markdown, "原格式" means its source text, including # and **.
        // An editor may also attach HTML/RTF, which is a separate representation.
        return classification == .markdown || !hasRichText ? .plain : .original
    }
}

struct TextPreviewResult {
    let text: NSAttributedString
    let notice: String?
    let actualRichText: Bool
}

// Each worker finishes constructing an immutable attributed string before it
// crosses back to the UI actor. Foundation has not annotated this class Sendable.
private struct PreviewTextBox: @unchecked Sendable {
    let value: NSAttributedString
}

enum TextPreviewRenderer {
    // These caps affect display only, never saved data or copying.
    static let maximumPreviewCharacters = 100_000
    static let maximumRichPreviewBytes = 2 * 1_024 * 1_024
    private static let maximumHTMLPreviewBytes = 128 * 1_024
    static let codeLanguages = [
        "自动", "Swift", "Objective-C", "HTML", "CSS", "JavaScript", "TypeScript",
        "JSON", "JSON Lines", "YAML", "XML", "SQL", "CSV", "Python", "Shell",
        "Java", "Kotlin", "Go", "Rust", "C", "C++", "C#", "PHP", "Ruby", "Dart"
    ]

    static func render(
        mode: TextPreviewMode,
        raw: String,
        files: RichTextSourceFiles,
        language: String = "自动",
        maximumCharacters: Int = maximumPreviewCharacters
    ) async -> TextPreviewResult {
        let limit = min(max(1, maximumCharacters), maximumPreviewCharacters)
        let limited = String(raw.prefix(limit))
        let truncated = !raw.dropFirst(limit).isEmpty
        let limitNotice = truncated ? "预览只显示前 \(limit) 字；复制仍使用完整原文。" : nil

        switch mode {
        case .plain:
            return TextPreviewResult(text: plain(limited), notice: limitNotice, actualRichText: false)
        case .markdown:
            // Copying a rendered Markdown preview often puts plain text without
            // #/** markers beside RTF or HTML that carries the visible styling.
            if !hasMarkdownSourceSyntax(raw),
               let rich = await loadSafeRichText(from: files, maximumCharacters: limit) {
                return TextPreviewResult(
                    text: clipped(themedMarkdown(rich.value), to: limit),
                    notice: rich.value.length > limit ? limitNotice : nil,
                    actualRichText: false
                )
            }
            let rendered = await background { PreviewTextBox(value: markdown(limited)) }
            return TextPreviewResult(text: rendered.value, notice: limitNotice, actualRichText: false)
        case .code:
            let rendered = await background { PreviewTextBox(value: code(limited, language: language)) }
            return TextPreviewResult(text: rendered.value, notice: limitNotice, actualRichText: false)
        case .original:
            if let rich = await loadSafeRichText(from: files, maximumCharacters: limit) {
                return TextPreviewResult(
                    text: clipped(rich.value, to: limit),
                    notice: rich.value.length > limit ? limitNotice : nil,
                    actualRichText: true
                )
            }
            return TextPreviewResult(
                text: plain(limited),
                notice: files.rtf != nil || files.rtfd != nil || files.html != nil
                    ? "这条记录的富文本太大、含外部资源或无法解析；当前显示原文，原格式复制仍可用。"
                    : limitNotice,
                actualRichText: false
            )
        }
    }

    private static func hasMarkdownSourceSyntax(_ raw: String) -> Bool {
        let sample = String(raw.prefix(8_192))
        for line in sample.split(separator: "\n") {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            guard indent <= 3 else { continue }
            let content = line.dropFirst(indent)
            let headings = content.prefix(while: { $0 == "#" }).count
            if (1...6).contains(headings), content.dropFirst(headings).first == " " {
                return true
            }
            if content.hasPrefix("```") || content.hasPrefix("~~~") || content.hasPrefix("> ") {
                return true
            }
        }
        return sample.contains("**") || sample.contains("__") ||
            sample.contains("](") || sample.contains("`")
    }

    private static func themedMarkdown(_ rich: NSAttributedString) -> NSAttributedString {
        let display = NSMutableAttributedString(attributedString: rich)
        let whole = NSRange(location: 0, length: display.length)
        display.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        display.removeAttribute(.backgroundColor, range: whole)
        rich.enumerateAttribute(.link, in: whole) { link, range, _ in
            if link != nil {
                display.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            }
        }
        return NSAttributedString(attributedString: display)
    }

    private static func loadSafeRichText(
        from files: RichTextSourceFiles, maximumCharacters: Int
    ) async -> PreviewTextBox? {
        for (url, type) in [(files.rtfd, NSAttributedString.DocumentType.rtfd),
                            (files.rtf, .rtf)] {
            if Task.isCancelled { return nil }
            guard let url else { continue }
            if let rich = await background({
                importRichText(at: url, type: type, maximumCharacters: maximumCharacters)
                    .map(PreviewTextBox.init(value:))
            }) { return rich }
        }
        guard let htmlURL = files.html,
              let html = await background({
                  readBounded(at: htmlURL, maximumBytes: maximumHTMLPreviewBytes)
              }) else { return nil }
        // AppKit's HTML importer must stay on the main thread. Refuse HTML that
        // can request remote resources or execute/insert active content.
        let source = String(data: html, encoding: .utf8)?.lowercased()
        // Office HTML commonly carries an inline stylesheet for fonts,
        // colors and table layout. It is safe to keep when it cannot
        // import fonts, images or other external resources.
        let unsafe = ["<script", "<iframe", "<object", "<embed", "<link", "<img",
                      "<video", "<audio", "<svg", "<base", "expression("]
        let externalAttribute = try? NSRegularExpression(pattern: "\\b(?:src|background)\\s*=")
        let hasExternalAttribute = source.map {
            externalAttribute?.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        } ?? true
        let externalCSS = try? NSRegularExpression(
            pattern: "(?:@\\s*import|u\\s*r\\s*l\\s*\\(|\\bsrc\\s*:)"
        )
        let hasExternalCSS = source.map {
            externalCSS?.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        } ?? true
        guard let source, !Task.isCancelled,
              !unsafe.contains(where: source.contains), !hasExternalAttribute, !hasExternalCSS else {
            return nil
        }
        return await importSafeHTML(html)
    }

    private static func clipped(_ value: NSAttributedString, to limit: Int) -> NSAttributedString {
        guard value.length > limit else { return value }
        let safeLength = String(value.string.prefix(limit)).utf16.count
        return value.attributedSubstring(from: NSRange(location: 0, length: safeLength))
    }

    private static func background<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let worker = Task.detached(priority: .utility, operation: work)
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    @MainActor
    private static func importSafeHTML(_ data: Data) -> PreviewTextBox? {
        guard let rich = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ), rich.length <= maximumPreviewCharacters else { return nil }
        return PreviewTextBox(value: onPaper(rich))
    }

    private static func readBounded(at url: URL, maximumBytes: Int) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func importRichText(
        at url: URL, type: NSAttributedString.DocumentType, maximumCharacters: Int
    ) -> NSAttributedString? {
        guard let data = readBounded(at: url, maximumBytes: maximumRichPreviewBytes),
              let rich = try? NSAttributedString(
                data: data,
                options: [.documentType: type],
                documentAttributes: nil
              ), rich.length <= maximumPreviewCharacters else { return nil }
        guard type == .rtf, !richContainsAttachment(rich) else { return onPaper(rich) }
        let embeddedImages = extractEmbeddedRTFImages(from: data)
        guard !embeddedImages.isEmpty else { return onPaper(rich) }
        let thumbnail = maximumCharacters < maximumPreviewCharacters
        let maximumSize = thumbnail ? CGSize(width: 160, height: 110) : CGSize(width: 430, height: 340)
        let display = NSMutableAttributedString(string: "")
        if !thumbnail { display.append(onPaper(rich)) }
        for image in thumbnail ? Array(embeddedImages.prefix(1)) : embeddedImages {
            guard let rendered = NSImage(data: image.data) else { continue }
            let scale = min(1, maximumSize.width / image.width, maximumSize.height / image.height)
            let attachment = NSTextAttachment()
            attachment.image = rendered
            attachment.bounds = CGRect(x: 0, y: 0, width: image.width * scale,
                                       height: image.height * scale)
            if !thumbnail { display.append(NSAttributedString(string: "\n")) }
            display.append(NSAttributedString(attachment: attachment))
            if thumbnail { display.append(NSAttributedString(string: "\n")) }
        }
        if thumbnail { display.append(onPaper(rich)) }
        return NSAttributedString(attributedString: display)
    }

    private static func richContainsAttachment(_ rich: NSAttributedString) -> Bool {
        var found = false
        rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) {
            value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private struct EmbeddedImage {
        let data: Data
        let width: CGFloat
        let height: CGFloat
    }

    /// Office RTF can contain image bytes even when AppKit's RTF importer
    /// drops its picture attachment. Only decode bytes embedded in the RTF.
    private static func extractEmbeddedRTFImages(from data: Data) -> [EmbeddedImage] {
        let bytes = [UInt8](data)
        let signatures: [(magic: [UInt8], control: String)] = [
            (Array("89504e470d0a1a0a".utf8), "\\pngblip"),
            (Array("ffd8ff".utf8), "\\jpegblip")
        ]
        var images: [EmbeddedImage] = []
        var totalPixels: Int64 = 0
        var cursor = 0
        while cursor < bytes.count && images.count < 4 {
            guard let signature = signatures.first(where: { signature in
                cursor + signature.magic.count <= bytes.count &&
                    zip(bytes[cursor..<(cursor + signature.magic.count)], signature.magic)
                        .allSatisfy { actual, expected in
                            actual == expected || (65...70).contains(actual) && actual + 32 == expected
                        }
            }) else { cursor += 1; continue }
            let start = cursor
            let contextStart = max(0, start - 4_096)
            let context = String(decoding: bytes[contextStart..<start], as: UTF8.self).lowercased()
            guard let pict = context.range(of: "\\pict", options: .backwards),
                  context[pict.lowerBound...].contains(signature.control) else {
                cursor += signature.magic.count
                continue
            }
            var decoded = Data()
            var upper: UInt8?
            while cursor < bytes.count {
                let value = bytes[cursor]
                if let nibble = hexNibble(value) {
                    if let high = upper {
                        decoded.append(high << 4 | nibble)
                        upper = nil
                        if decoded.count > 4 * 1_024 * 1_024 {
                            cursor += 1
                            break
                        }
                    } else { upper = nibble }
                } else if value == 32 || value == 9 || value == 10 || value == 13 {
                    // RTF writers may wrap a hexadecimal picture stream.
                } else { break }
                cursor += 1
            }
            guard !decoded.isEmpty, decoded.count <= 4 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(decoded as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  width <= 20_000, height <= 20_000,
                  totalPixels + Int64(width) * Int64(height) <= 40_000_000,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { continue }
            totalPixels += Int64(width) * Int64(height)
            images.append(EmbeddedImage(data: decoded, width: CGFloat(width), height: CGFloat(height)))
        }
        return images
    }

    private static func hexNibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: value - 48
        case 65...70: value - 65 + 10
        case 97...102: value - 97 + 10
        default: nil
        }
    }

    private static func onPaper(_ rich: NSAttributedString) -> NSAttributedString {
        let display = NSMutableAttributedString(attributedString: rich)
        var uncolored: [NSRange] = []
        display.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: display.length)) {
            value, range, _ in
            if value == nil { uncolored.append(range) }
        }
        for range in uncolored {
            display.addAttribute(.foregroundColor, value: NSColor.black, range: range)
        }
        return NSAttributedString(attributedString: display)
    }

    private static func plain(_ value: String) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
    }

    private static func markdown(_ raw: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let lines = raw.components(separatedBy: "\n")
        var fencedLanguage: String?
        for (index, line) in lines.enumerated() {
            if Task.isCancelled { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                fencedLanguage = fencedLanguage == nil ? String(trimmed.dropFirst(3)) : nil
                if index < lines.count - 1 { output.append(NSAttributedString(string: "\n")) }
                continue
            }
            if let fencedLanguage {
                output.append(code(line, language: fencedLanguage.isEmpty ? "自动" : fencedLanguage))
            } else {
                let level = min(6, line.prefix(while: { $0 == "#" }).count)
                let isHeading = level > 0 && line.dropFirst(level).first == " "
                let isQuote = trimmed.hasPrefix("> ")
                let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
                let body: String
                if isHeading {
                    body = String(line.dropFirst(level + 1))
                } else if isQuote || isBullet {
                    body = String(trimmed.dropFirst(2))
                } else {
                    body = line
                }
                if isQuote { output.append(NSAttributedString(string: "│  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor
                ])) }
                if isBullet { output.append(NSAttributedString(string: "•  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor
                ])) }
                let baseSize: CGFloat = isHeading ? max(14, 24 - CGFloat(level - 1) * 2) : 13
                appendMarkdownInline(body, to: output, size: baseSize, heading: isHeading, quote: isQuote)
            }
            if index < lines.count - 1 { output.append(NSAttributedString(string: "\n")) }
        }
        return NSAttributedString(attributedString: output)
    }

    private static func appendMarkdownInline(
        _ line: String, to output: NSMutableAttributedString,
        size: CGFloat, heading: Bool, quote: Bool
    ) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: line, options: options) else {
            output.append(NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: size)]))
            return
        }
        for run in parsed.runs {
            let fragment = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent
            let mono = intent?.contains(.code) == true
            let bold = heading || intent?.contains(.stronglyEmphasized) == true
            let italic = intent?.contains(.emphasized) == true
            let font: NSFont
            if mono {
                font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .medium)
            } else {
                let base = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
                font = italic
                    ? (NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base)
                    : base
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: quote ? NSColor.secondaryLabelColor : NSColor.labelColor
            ]
            if mono { attributes[.backgroundColor] = NSColor.controlColor }
            if run.link != nil {
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                // The preview is intentionally non-navigating; raw text and paste data are unchanged.
            }
            if intent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: fragment, attributes: attributes))
        }
    }

    private static func code(_ raw: String, language: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: raw, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
        guard !raw.isEmpty else { return output }
        let chosen = language.lowercased()
        let keywords: String
        if chosen.contains("json") || (chosen == "自动" && raw.first == "{") {
            keywords = "true|false|null"
        } else if chosen.contains("sql") {
            keywords = "SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|GROUP|ORDER|BY|INSERT|INTO|UPDATE|SET|DELETE|CREATE|TABLE|AS|AND|OR|NULL|LIMIT"
        } else if chosen.contains("yaml") {
            keywords = "true|false|null|yes|no"
        } else if chosen.contains("typescript") {
            keywords = "interface|type|extends|implements|readonly|export|import|const|let|function|return|async|await|new|class|public|private|true|false|null|undefined|string|number|boolean"
        } else if chosen == "html" || chosen == "xml" {
            keywords = ""
        } else if chosen.contains("python") || chosen == "py" {
            keywords = "def|class|return|if|else|elif|for|while|in|import|from|as|try|except|with|async|await|True|False|None"
        } else if chosen.contains("shell") || chosen.contains("bash") || chosen == "sh" {
            keywords = "if|then|else|fi|for|do|done|case|esac|function|export|local"
        } else if chosen == "java" || chosen == "kotlin" || chosen == "c#" || chosen == "dart" {
            keywords = "class|interface|enum|record|package|import|public|private|protected|static|final|abstract|override|fun|val|var|return|if|else|for|while|try|catch|throw|new|this|super|true|false|null|void|async|await|using|namespace"
        } else if chosen == "go" || chosen == "rust" {
            keywords = "package|import|func|type|struct|interface|return|if|else|for|range|go|defer|select|case|fn|let|mut|pub|impl|trait|enum|match|use|mod|async|await|true|false|nil|None|Some"
        } else if chosen == "c" || chosen == "c++" || chosen == "objective-c" {
            keywords = "include|define|typedef|struct|enum|class|namespace|template|typename|using|public|private|protected|static|const|auto|void|int|char|float|double|bool|return|if|else|for|while|new|delete|true|false|nil|NULL"
        } else if chosen == "php" || chosen == "ruby" {
            keywords = "class|module|def|function|public|private|protected|return|if|else|elsif|end|do|while|foreach|for|use|require|include|new|true|false|null|nil|self"
        } else {
            keywords = "let|var|func|struct|class|enum|protocol|extension|import|return|if|else|guard|switch|case|for|while|in|try|catch|throw|async|await|private|public|static|true|false|nil|const|function|new|this|null|undefined"
        }
        // Paint keywords/numbers first; strings and comments take precedence.
        if !keywords.isEmpty {
            colorMatches("\\b(?:\(keywords))\\b", in: raw, output: output, color: .systemPurple)
        }
        colorMatches("\\b\\d+(?:\\.\\d+)?\\b", in: raw, output: output, color: .systemOrange)
        colorMatches("\\\"(?:\\\\.|[^\\\"\\\\])*\\\"|'(?:\\\\.|[^'\\\\])*'", in: raw, output: output, color: .systemRed)
        let commentPattern: String?
        if chosen.contains("json") || chosen.contains("csv") {
            commentPattern = nil
        } else if chosen.contains("css") {
            commentPattern = "(?s)/\\*.*?\\*/"
        } else if chosen.contains("sql") {
            commentPattern = "(?m)--[^\\n]*|/\\*[^*]*\\*/"
        } else if chosen.contains("xml") || chosen.contains("html") {
            commentPattern = "(?s)<!--.*?-->"
        } else if chosen.contains("yaml") || chosen.contains("python") || chosen.contains("shell") || chosen == "ruby" {
            commentPattern = "(?m)#[^\\n]*"
        } else {
            commentPattern = "(?m)//[^\\n]*|/\\*[^*]*\\*/"
        }
        if let commentPattern {
            colorMatches(commentPattern, in: raw, output: output, color: .systemGreen)
        }
        if chosen.contains("json") {
            colorMatches("\\\"(?:\\\\.|[^\\\"\\\\])*\\\"(?=\\s*:)", in: raw, output: output, color: .systemBlue)
        } else if chosen.contains("yaml") || chosen.contains("css") {
            colorMatches("(?m)^\\s*[A-Za-z_][\\w-]*(?=\\s*:)", in: raw, output: output, color: .systemBlue)
        } else if chosen.contains("xml") || chosen.contains("html") {
            colorMatches("</?[A-Za-z][\\w:.-]*", in: raw, output: output, color: .systemBlue)
        }
        return NSAttributedString(attributedString: output)
    }

    private static func colorMatches(
        _ pattern: String, in raw: String,
        output: NSMutableAttributedString, color: NSColor
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        for match in expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            output.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
