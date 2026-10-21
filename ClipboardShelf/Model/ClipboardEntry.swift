import Foundation
import UniformTypeIdentifiers

struct ClipboardEntry: Identifiable, Equatable {
    enum Kind: String {
        case text
        case link
        case image
        case unavailableImage
        case fileReference
        case group
    }

    let id: UUID
    // `createdAt` remains the most recent copy time for existing views.
    var createdAt: Date
    var firstCopiedAt: Date?
    var copyCount: Int?
    let kind: Kind
    let text: String?
    let imageFileName: String?
    let imagePasteboardType: String?
    let digest: String
    let byteCount: Int
    var sourceAppName: String?
    var sourceAppBundleID: String?
    var rtfFileName: String? = nil
    var htmlFileName: String? = nil
    var rtfdFileName: String? = nil
    var filePath: String? = nil
    var fileName: String? = nil
    var fileType: String? = nil
    var fileBookmarkName: String? = nil
    var fileCopyName: String? = nil
    /// Ordered references are persisted; snapshots are filled for root cards.
    var groupMemberIDs: [UUID] = []
    var groupMembers: [ClipboardEntry] = []

    var hasRichText: Bool {
        rtfFileName != nil || htmlFileName != nil || rtfdFileName != nil
    }

    var containsUnavailableImage: Bool {
        kind == .unavailableImage || (kind == .group && groupMembers.contains {
            $0.kind == .unavailableImage
        })
    }

    var isImagePreviewable: Bool {
        if kind == .image { return true }
        guard kind == .fileReference else { return false }
        let type = fileType.flatMap(UTType.init)
            ?? UTType(filenameExtension: URL(fileURLWithPath: fileName ?? "").pathExtension)
        return type?.conforms(to: .image) == true
    }

    var title: String {
        switch kind {
        case .image:
            return "图片"
        case .unavailableImage:
            return "图片未保存"
        case .fileReference:
            return fileName ?? "文件"
        case .link:
            return webURL?.host ?? "链接"
        case .text:
            // A history entry may contain a multi-megabyte export. Never split
            // every line just to show the first few characters on a card.
            let firstLine = String((text ?? "").prefix(256))
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.isEmpty ? "文本" : String(firstLine.prefix(30))
        case .group:
            return "\(groupMemberIDs.count) 项内容"
        }
    }

    var webURL: URL? {
        guard kind == .link, let text else { return nil }
        return Self.webURL(from: text)
    }

    static func webURL(from value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

enum ClipboardFileIconKind: Hashable {
    case image, pdf, word, spreadsheet, presentation, archive, video, audio, code, generic

    static func classify(fileName: String?, fileType: String?) -> Self {
        let ext = URL(fileURLWithPath: fileName ?? "").pathExtension.lowercased()
        let type = fileType.flatMap(UTType.init) ?? UTType(filenameExtension: ext)
        if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg"].contains(ext)
            || type?.conforms(to: .image) == true { return .image }
        if ext == "pdf" || type?.conforms(to: .pdf) == true { return .pdf }
        if ["doc", "docx", "pages", "odt"].contains(ext) { return .word }
        if ["xls", "xlsx", "numbers", "ods"].contains(ext) { return .spreadsheet }
        if ["ppt", "pptx", "key", "odp"].contains(ext) { return .presentation }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg"].contains(ext) { return .archive }
        if ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext)
            || type?.conforms(to: .movie) == true { return .video }
        if ["mp3", "m4a", "wav", "aiff", "flac", "ogg"].contains(ext)
            || type?.conforms(to: .audio) == true { return .audio }
        if ["swift", "py", "js", "ts", "html", "css", "json", "xml", "sh"].contains(ext) {
            return .code
        }
        return .generic
    }
}

/// One definition drives the menu, result list, and counts. An image file
/// reference intentionally appears under both Images and Files.
enum ClipboardFilter: Hashable {
    case all, plainText, richText, markdown, code, link, image, files
    case codeLanguage(ClipboardTextClassification)
    case fileKind(ClipboardFileIconKind)

    static let primary: [Self] = [
        .all, .plainText, .richText, .markdown, .code, .link, .image, .files
    ]

    static let codeLanguages: [ClipboardTextClassification] = [
        .swift, .json, .jsonLines, .yaml, .xml, .css, .sql, .csv,
        .python, .javaScript, .typeScript, .shell, .html, .objectiveC,
        .java, .kotlin, .go, .rust, .c, .cpp, .cSharp, .php, .ruby,
        .dart, .code
    ]

    static let fileKinds: [ClipboardFileIconKind] = [
        .image, .pdf, .word, .spreadsheet, .presentation, .archive,
        .video, .audio, .code, .generic
    ]

    var label: String {
        switch self {
        case .all: "全部"
        case .plainText: "文字"
        case .richText: "富文本"
        case .markdown: "Markdown"
        case .code: "代码"
        case .link: "链接"
        case .image: "图片"
        case .files: "文件"
        case .codeLanguage(let language): language.label
        case .fileKind(let kind):
            switch kind {
            case .image: "图片文件"
            case .pdf: "PDF"
            case .word: "Word 与文稿"
            case .spreadsheet: "表格"
            case .presentation: "演示文稿"
            case .archive: "压缩包"
            case .video: "视频"
            case .audio: "音频"
            case .code: "代码文件"
            case .generic: "其他文件"
            }
        }
    }

    var compactLabel: String {
        switch self {
        case .codeLanguage(let language):
            switch language {
            case .javaScript: "JS"
            case .typeScript: "TS"
            case .objectiveC: "Obj-C"
            case .cSharp: "C#"
            case .jsonLines: "JSONL"
            default: language.codeLanguage ?? "代码"
            }
        case .fileKind(let kind):
            switch kind {
            case .word: "Word"
            case .presentation: "演示"
            case .spreadsheet: "表格"
            case .archive: "压缩包"
            case .generic: "其他"
            case .image: "图片"
            case .pdf: "PDF"
            case .video: "视频"
            case .audio: "音频"
            case .code: "代码"
            }
        default: label
        }
    }

    func matches(_ entry: ClipboardEntry) -> Bool {
        if entry.kind == .group {
            return self == .all || entry.groupMembers.contains { matches($0) }
        }
        return switch self {
        case .all: true
        case .plainText: entry.kind == .text && entry.textClassification == .plain
        case .richText: entry.kind == .text && entry.textClassification == .rich
        case .markdown: entry.kind == .text && entry.textClassification == .markdown
        case .code: entry.kind == .text && entry.textClassification.codeLanguage != nil
        case .link: entry.kind == .link
        case .image: entry.isImagePreviewable || entry.kind == .unavailableImage
        case .files: entry.kind == .fileReference
        case .codeLanguage(let language):
            entry.kind == .text && entry.textClassification == language
        case .fileKind(let kind):
            entry.kind == .fileReference &&
            ClipboardFileIconKind.classify(fileName: entry.fileName, fileType: entry.fileType) == kind
        }
    }
}

struct ClipboardFilterInventory {
    private(set) var counts: [ClipboardFilter: Int] = [:]

    init(entries: [ClipboardEntry]) {
        counts[.all] = entries.count
        for entry in entries {
            var matched: Set<ClipboardFilter> = []
            for item in entry.kind == .group ? entry.groupMembers : [entry] {
                switch item.kind {
            case .text:
                let classification = item.textClassification
                switch classification {
                case .plain: matched.insert(.plainText)
                case .rich: matched.insert(.richText)
                case .markdown: matched.insert(.markdown)
                default:
                    matched.insert(.code)
                    matched.insert(.codeLanguage(classification))
                }
            case .link: matched.insert(.link)
            case .image, .unavailableImage: matched.insert(.image)
            case .fileReference:
                matched.insert(.files)
                let kind = ClipboardFileIconKind.classify(
                    fileName: item.fileName, fileType: item.fileType
                )
                matched.insert(.fileKind(kind))
                if kind == .image { matched.insert(.image) }
            case .group: break
                }
            }
            for filter in matched { increment(filter) }
        }
    }

    func count(for filter: ClipboardFilter) -> Int { counts[filter, default: 0] }

    func matching(_ entries: [ClipboardEntry], filter: ClipboardFilter, query: String) -> [ClipboardEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if filter == .all && trimmedQuery.isEmpty { return entries }
        return entries.filter { entry in
            guard filter.matches(entry) else { return false }
            guard !trimmedQuery.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(trimmedQuery)
                || (entry.text?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (entry.sourceAppName?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (entry.fileType?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || entry.groupMembers.contains { member in
                    member.title.localizedCaseInsensitiveContains(trimmedQuery)
                        || (member.text?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                        || (member.fileName?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                }
        }
    }

    private mutating func increment(_ filter: ClipboardFilter) {
        counts[filter, default: 0] += 1
    }
}
