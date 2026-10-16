import Foundation

struct ClipboardEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case link
        case image
    }

    let id: UUID
    var createdAt: Date
    let kind: Kind
    let text: String?
    let imageFileName: String?
    let imagePasteboardType: String?
    let digest: String
    let byteCount: Int
    var sourceAppName: String?

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

    var symbolName: String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        }
    }
}
