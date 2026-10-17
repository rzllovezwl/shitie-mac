import Foundation

struct ClipboardEntry: Identifiable, Equatable {
    enum Kind: String {
        case text
        case link
        case image
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

    var title: String {
        switch kind {
        case .image:
            return "图片"
        case .link:
            return URL(string: text ?? "")?.host ?? "链接"
        case .text:
            let firstLine = text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return firstLine.isEmpty ? "文本" : String(firstLine.prefix(30))
        }
    }
}
