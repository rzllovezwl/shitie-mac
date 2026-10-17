import Foundation

struct ClipboardEntry: Identifiable, Equatable {
    enum Kind: String {
        case text
        case link
        case image
        case fileReference
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

    var hasRichText: Bool {
        rtfFileName != nil || htmlFileName != nil || rtfdFileName != nil
    }

    var title: String {
        switch kind {
        case .image:
            return "图片"
        case .fileReference:
            return fileName ?? "文件"
        case .link:
            return URL(string: text ?? "")?.host ?? "链接"
        case .text:
            let firstLine = text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.isEmpty ? "文本" : String(firstLine.prefix(30))
        }
    }
}
