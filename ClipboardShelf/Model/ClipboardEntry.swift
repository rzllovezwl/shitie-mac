import Foundation
import UniformTypeIdentifiers

struct ClipboardRecordingMetadata: Codable, Equatable {
    let duration: Double
    let width: Int
    let height: Int
    let frameRate: Int

    var durationLabel: String {
        let seconds = max(0, Int(duration.isFinite ? duration.rounded(.down) : 0))
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Capture channel is independent of the application visible in a screenshot.
enum ClipboardScreenshotOrigin: String, CaseIterable {
    case screen, cliphoook, phone, ordinaryImage

    /// These are screenshot applications, not general image editors. Bundle
    /// identifiers take precedence; names are a fallback for older history.
    static func knownSource(name: String?, bundleID: String?) -> Self? {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "iPhone 截图" { return .phone }
        if name == "Mac 截图" || name == "Mac 截图（已标注）" { return .cliphoook }
        if let id = bundleID?.lowercased(), !id.isEmpty {
            let screenshotApps: Set<String> = [
                "com.apple.screencaptureui", "com.apple.screencapture",
                "pl.maketheweb.cleanshotx", "com.snipaste", "com.zzd.xnip", "com.zzd.xniphelper"
            ]
            return screenshotApps.contains(id) ? .screen : nil
        }
        let legacyNames: Set<String> = ["cleanshot x", "cleanshot", "snipaste", "xnip"]
        return name.map { legacyNames.contains($0.lowercased()) } == true ? .screen : nil
    }

    var label: String {
        switch self {
        case .screen: "屏幕截屏"
        case .cliphoook: "ClipHoook截图"
        case .phone: "iPhone 截图"
        case .ordinaryImage: "普通图片"
        }
    }
}

struct ClipboardEntry: Identifiable, Equatable {
    enum Kind: String {
        case text
        case link
        case image
        case unavailableImage
        case fileReference
        case group

        var isTextual: Bool { self == .text || self == .link }
    }

    let id: UUID
    // `createdAt` remains the most recent copy time for existing views.
    var createdAt: Date
    var firstCopiedAt: Date?
    var copyCount: Int?
    var kind: Kind
    var text: String?
    let imageFileName: String?
    let imagePasteboardType: String?
    var digest: String
    var byteCount: Int
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
    var isFavorite = false
    var favoriteCategoryID: UUID? = nil
    var shelfPinOrder: Int64? = nil
    var cardOrders: [String: ClipboardCardOrder] = [:]
    /// A completed recognition can be empty when the image contains no text.
    var ocrText: String? = nil
    /// Ordered references are persisted; snapshots are filled for root cards.
    var groupMemberIDs: [UUID] = []
    var groupMembers: [ClipboardEntry] = []
    var screenshotOrigin: ClipboardScreenshotOrigin? = nil
    var textRevision: UUID? = nil
    /// Nil means an old record with only first/latest timestamps available.
    /// An empty array is intentional (e.g. grouping without copying).
    var recordedAt: [Date]? = nil
    var screenRecording: ClipboardRecordingMetadata? = nil

    var isScreenRecording: Bool { kind == .fileReference && screenRecording != nil }

    var resolvedScreenshotOrigin: ClipboardScreenshotOrigin? {
        guard isImagePreviewable || kind == .unavailableImage else { return nil }
        if let screenshotOrigin { return screenshotOrigin }
        return ClipboardScreenshotOrigin.knownSource(name: sourceAppName, bundleID: sourceAppBundleID)
    }

    var calendarRecordTimes: [Date] {
        if let recordedAt { return recordedAt }
        guard kind != .group else { return [] }
        return Array(Set([createdAt] + (firstCopiedAt.map { [$0] } ?? []))).sorted()
    }

    func wasRecorded(on date: Date, calendar: Calendar = .current) -> Bool {
        calendarRecordTimes.contains { calendar.isDate($0, inSameDayAs: date) }
    }

    var hasRichText: Bool {
        rtfFileName != nil || htmlFileName != nil || rtfdFileName != nil
    }

    var isEditableText: Bool { kind.isTextual && text != nil }

    var textFileName: String {
        if let textRevision { return "\(id.uuidString)-\(textRevision.uuidString).txt" }
        return "\(id.uuidString).txt"
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

struct ClipboardCardOrder: Equatable {
    let position: Int64
    let copiedAt: Date
}

enum ClipboardCardOrderScope: Hashable {
    case history, favorite(UUID), pins, group(UUID)

    var storageKey: String? {
        switch self {
        case .history: "history"
        case .favorite(let id): "favorite:\(id.uuidString)"
        case .pins, .group: nil
        }
    }
}

enum ClipboardCardReordering {
    static func sorted(_ entries: [ClipboardEntry], in scope: ClipboardCardOrderScope) -> [ClipboardEntry] {
        guard let key = scope.storageKey else { return entries }
        func rank(_ entry: ClipboardEntry) -> Int64? {
            guard let order = entry.cardOrders[key] else { return nil }
            // A newly copied history item returns to the front. Favorites
            // keep their chosen order even if the item is copied again.
            if scope == .history, order.copiedAt != entry.createdAt { return nil }
            return order.position
        }
        return entries.enumerated().sorted { lhs, rhs in
            switch (rank(lhs.element), rank(rhs.element)) {
            case (.some(let a), .some(let b)) where a != b: return a < b
            case (.none, .some): return true
            case (.some, .none): return false
            default:
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt > rhs.element.createdAt
                }
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    static func moving(_ ids: [UUID], relativeTo target: UUID, after: Bool,
                       in order: [UUID]) -> [UUID]? {
        let chosen = Set(ids)
        guard !chosen.isEmpty, !chosen.contains(target), Set(order).count == order.count,
              chosen.isSubset(of: Set(order)) else { return nil }
        var remaining = order.filter { !chosen.contains($0) }
        guard let index = remaining.firstIndex(of: target) else { return nil }
        let moved = order.filter { chosen.contains($0) }
        remaining.insert(contentsOf: moved, at: index + (after ? 1 : 0))
        return remaining == order ? nil : remaining
    }
}

struct ClipboardCalendarMonth {
    let start: Date
    let calendar: Calendar

    init(containing date: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    var cells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).map { index in
            let offset = index - leading
            guard offset >= 0 && offset < range.count else { return nil }
            return calendar.date(byAdding: .day, value: offset, to: start)
        }
    }

    func shifted(by months: Int) -> Date {
        calendar.date(byAdding: .month, value: months, to: start) ?? start
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
    case all, favorites, plainText, richText, markdown, code, link, image, phoneScreenshot, screenScreenshot, cliphoookScreenshot, files
    case codeLanguage(ClipboardTextClassification)
    case fileKind(ClipboardFileIconKind)

    static let primary: [Self] = [
        .all, .favorites, .plainText, .richText, .markdown, .code, .link, .image,
        .phoneScreenshot, .screenScreenshot, .cliphoookScreenshot, .files
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
        case .favorites: "收藏"
        case .plainText: "文字"
        case .richText: "富文本"
        case .markdown: "Markdown"
        case .code: "代码"
        case .link: "链接"
        case .image: "图片"
        case .phoneScreenshot: "iPhone 截图"
        case .screenScreenshot: "屏幕截屏"
        case .cliphoookScreenshot: "ClipHoook截图"
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
        case .phoneScreenshot: "iPhone"
        case .screenScreenshot: "屏幕截屏"
        case .cliphoookScreenshot: "ClipHoook"
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
        if self == .favorites {
            return entry.isFavorite || entry.groupMembers.contains(where: \.isFavorite)
        }
        if entry.kind == .group {
            return self == .all || entry.groupMembers.contains { matches($0) }
        }
        return switch self {
        case .all: true
        case .favorites: entry.isFavorite
        case .plainText: entry.kind == .text && entry.textClassification == .plain
        case .richText: entry.kind == .text && entry.textClassification == .rich
        case .markdown: entry.kind == .text && entry.textClassification == .markdown
        case .code: entry.kind == .text && entry.textClassification.codeLanguage != nil
        case .link: entry.kind == .link
        case .image: entry.isImagePreviewable || entry.kind == .unavailableImage
        case .phoneScreenshot: entry.resolvedScreenshotOrigin == .phone
        case .screenScreenshot: entry.resolvedScreenshotOrigin == .screen
        case .cliphoookScreenshot: entry.resolvedScreenshotOrigin == .cliphoook
        case .files: entry.kind == .fileReference
        case .codeLanguage(let language):
            entry.kind == .text && entry.textClassification == language
        case .fileKind(let kind):
            entry.kind == .fileReference &&
            ClipboardFileIconKind.classify(fileName: entry.fileName, fileType: entry.fileType) == kind
        }
    }
}

struct ClipboardFavoriteCategory: Identifiable, Equatable {
    enum Tint: String, CaseIterable {
        case blue, teal, green, orange, red, pink, purple, gray
    }

    enum Icon: String, CaseIterable {
        case password, account, email, phoneNumber, address, identity, paymentCard, lock
        case star, clipboard, file, image, braces, pin, pencil
        case link = "link-2"
        case folder, briefcase, notes, checklist, calendar, clock, bookmark, archive
        case camera, video, audio, mic, palette, globe, chat, tag
        case heart, home, shopping, gift, travel, car, food, fitness

        var presentation: (emoji: String, label: String) {
            switch self {
            case .password: ("🔑", "密码")
            case .account: ("👤", "账号")
            case .email: ("📧", "邮箱")
            case .phoneNumber: ("📱", "手机号")
            case .address: ("📍", "地址")
            case .identity: ("🪪", "证件")
            case .paymentCard: ("💳", "银行卡")
            case .lock: ("🔒", "私密")
            case .star: ("⭐", "星标")
            case .clipboard: ("📋", "剪贴板")
            case .file: ("📄", "文件")
            case .image: ("🖼️", "图片")
            case .braces: ("💻", "代码")
            case .pin: ("📌", "图钉")
            case .pencil: ("✏️", "铅笔")
            case .link: ("🔗", "链接")
            case .folder: ("📁", "文件夹")
            case .briefcase: ("💼", "工作")
            case .notes: ("📓", "笔记")
            case .checklist: ("✅", "待办")
            case .calendar: ("📅", "日程")
            case .clock: ("🕒", "时间")
            case .bookmark: ("🔖", "书签")
            case .archive: ("🗃️", "归档")
            case .camera: ("📷", "相机")
            case .video: ("🎬", "视频")
            case .audio: ("🎧", "音频")
            case .mic: ("🎙️", "录音")
            case .palette: ("🎨", "设计")
            case .globe: ("🌐", "网页")
            case .chat: ("💬", "聊天")
            case .tag: ("🏷️", "标签")
            case .heart: ("❤️", "喜爱")
            case .home: ("🏠", "家庭")
            case .shopping: ("🛒", "购物")
            case .gift: ("🎁", "礼物")
            case .travel: ("✈️", "旅行")
            case .car: ("🚗", "出行")
            case .food: ("🍽️", "餐饮")
            case .fitness: ("🏅", "运动")
            }
        }
    }

    let id: UUID
    let name: String
    let tint: Tint
    let icon: Icon
}

struct ClipboardShelfNavigation: Equatable {
    enum Tab: Hashable {
        case history, favoriteCategory(UUID)

        func includes(_ entry: ClipboardEntry) -> Bool {
            switch self {
            case .history: true
            case .favoriteCategory(let id): entry.isFavorite && entry.favoriteCategoryID == id
            }
        }

        func members(of entry: ClipboardEntry) -> [ClipboardEntry] {
            let members = entry.kind == .group ? entry.groupMembers : [entry]
            return includes(entry) ? members : members.filter(includes)
        }
    }

    struct Filters: Equatable {
        var query = ""
        var type: ClipboardFilter = .all
        var date: Date?
    }

    var tab: Tab = .history
    private var tabFilters: [Tab: Filters] = [:]

    var filters: Filters {
        get { tabFilters[tab] ?? Filters() }
        set { tabFilters[tab] = newValue }
    }

    mutating func removeCategory(_ id: UUID) {
        let removedTab = Tab.favoriteCategory(id)
        tabFilters.removeValue(forKey: removedTab)
        if tab == removedTab { tab = .history }
    }
}

struct ClipboardImageSearchScope: Equatable {
    let filter: ClipboardFilter
    let date: Date?
    let tab: ClipboardShelfNavigation.Tab
}

struct ClipboardFilterInventory {
    private(set) var counts: [ClipboardFilter: Int] = [:]

    init(entries: [ClipboardEntry], tab: ClipboardShelfNavigation.Tab = .history) {
        for entry in entries {
            let included = tab.members(of: entry)
            guard tab == .history || !included.isEmpty else { continue }
            increment(.all)
            var matched: Set<ClipboardFilter> = []
            if ClipboardFilter.favorites.matches(entry) { matched.insert(.favorites) }
            for item in included {
                switch item.resolvedScreenshotOrigin {
                case .screen: matched.insert(.screenScreenshot)
                case .cliphoook: matched.insert(.cliphoookScreenshot)
                case .phone: matched.insert(.phoneScreenshot)
                default: break
                }
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
            case .image, .unavailableImage:
                matched.insert(.image)
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

    func matching(_ entries: [ClipboardEntry], filter: ClipboardFilter, query: String,
                  date: Date? = nil, calendar: Calendar = .current,
                  tab: ClipboardShelfNavigation.Tab = .history) -> [ClipboardEntry] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if filter == .all && trimmedQuery.isEmpty && date == nil && tab == .history { return entries }
        return entries.filter { entry in
            Self.matchingMembers(of: entry, filter: filter, query: trimmedQuery, tab: tab).contains { item in
                date.map { item.wasRecorded(on: $0, calendar: calendar) } ?? true
            }
        }
    }

    /// One card is counted once per day, even if several group members or
    /// repeated copies match. Uses the same member predicates as the list.
    func dailyCounts(_ entries: [ClipboardEntry], filter: ClipboardFilter,
                     query: String, calendar: Calendar = .current,
                     tab: ClipboardShelfNavigation.Tab = .history) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for entry in entries {
            let days = Set(Self.matchingMembers(of: entry, filter: filter, query: query, tab: tab)
                .flatMap(\.calendarRecordTimes).map { calendar.startOfDay(for: $0) })
            for day in days { counts[day, default: 0] += 1 }
        }
        return counts
    }

    static func unrecognizedImages(in entries: [ClipboardEntry], scope: ClipboardImageSearchScope,
                                   calendar: Calendar = .current) -> [ClipboardEntry] {
        var seen = Set<UUID>()
        return entries.flatMap { entry in
            matchingMembers(of: entry, filter: scope.filter, query: "", tab: scope.tab)
                .filter { item in
                    guard item.ocrText == nil, item.isImagePreviewable,
                          scope.date.map({ item.wasRecorded(on: $0, calendar: calendar) }) ?? true
                    else { return false }
                    return seen.insert(item.id).inserted
                }
        }
    }

    private static func matchingMembers(of entry: ClipboardEntry, filter: ClipboardFilter,
                                        query: String, tab: ClipboardShelfNavigation.Tab) -> [ClipboardEntry] {
        tab.members(of: entry).filter { item in
            let matchesFilter = filter == .favorites
                ? (entry.isFavorite || item.isFavorite) : filter.matches(item)
            guard matchesFilter else { return false }
            if query.isEmpty { return true }
            // A group's source/title describes all of its members. A match
            // in one member must never satisfy another member's date/type.
            return searchableStrings(of: item, in: entry).contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    static func searchableStrings(of item: ClipboardEntry, in entry: ClipboardEntry) -> [String] {
        let context = entry.kind == .group ? [entry.title, entry.sourceAppName ?? ""] : []
        return [item.title, item.text ?? "", item.ocrText ?? "", item.sourceAppName ?? "",
                item.fileName ?? "", item.fileType ?? ""] + context
    }

    private mutating func increment(_ filter: ClipboardFilter) {
        counts[filter, default: 0] += 1
    }
}
