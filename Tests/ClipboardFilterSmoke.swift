import Foundation

@main
struct ClipboardFilterSmoke {
    enum Failure: Error { case unexpected(String) }

    static func main() throws {
        var plain = entry(.text, "A plain note")
        plain.sourceAppName = "Notes"
        var rich = entry(.text, "Styled document")
        rich.rtfFileName = "styled.rtf"
        let markdown = entry(.text, "# Release notes\n\n**Important**")
        var swift = entry(.text, "import SwiftUI\nstruct AppView: View {}")
        swift.sourceAppName = "Xcode"
        let json = entry(.text, "{\"count\":2}")
        let link = entry(.link, " https://example.com/path?q=1 \n")
        let image = entry(.image, nil)
        let imageFile = entry(.fileReference, nil, fileName: "photo.png")
        let pdf = entry(.fileReference, nil, fileName: "report.pdf")
        let word = entry(.fileReference, nil, fileName: "draft.docx")
        let archive = entry(.fileReference, nil, fileName: "backup.zip")
        let entries = [plain, rich, markdown, swift, json, link, image, imageFile, pdf, word, archive]
        let inventory = ClipboardFilterInventory(entries: entries)

        try expect(inventory.count(for: .all), 11, "全部")
        try expect(inventory.count(for: .plainText), 1, "文字")
        try expect(inventory.count(for: .richText), 1, "富文本")
        try expect(inventory.count(for: .markdown), 1, "Markdown")
        try expect(inventory.count(for: .code), 2, "代码")
        try expect(inventory.count(for: .codeLanguage(.swift)), 1, "Swift")
        try expect(inventory.count(for: .codeLanguage(.json)), 1, "JSON")
        try expect(inventory.count(for: .link), 1, "链接")
        try expect(inventory.count(for: .image), 2, "图片含图片文件")
        try expect(inventory.count(for: .files), 4, "文件含图片文件")
        try expect(inventory.count(for: .fileKind(.pdf)), 1, "PDF")
        try expect(inventory.count(for: .fileKind(.word)), 1, "Word")
        try expect(inventory.count(for: .fileKind(.archive)), 1, "压缩包")
        try expect(inventory.matching(entries, filter: .code, query: "Xcode").count,
                   1, "分类内搜索来源应用")
        try expect(inventory.matching(entries, filter: .files, query: "report").count,
                   1, "分类内搜索文件名")
        try expect(inventory.matching(entries, filter: .plainText, query: "report").count,
                   0, "分类与搜索取交集")
        var phoneScreenshot = entry(.image, nil)
        phoneScreenshot.sourceAppName = "iPhone 截图"
        var otherImage = entry(.image, nil)
        otherImage.sourceAppName = "微信"
        var mislabeledText = entry(.text, "ordinary text")
        mislabeledText.sourceAppName = "iPhone 截图"
        var phoneGroupMember = entry(.image, nil)
        phoneGroupMember.sourceAppName = "iPhone 截图"
        var group = entry(.group, nil)
        group.groupMemberIDs = [phoneGroupMember.id]
        group.groupMembers = [phoneGroupMember]
        let sourceEntries = [phoneScreenshot, otherImage, mislabeledText, group]
        let sourceInventory = ClipboardFilterInventory(entries: sourceEntries)
        try expect(sourceInventory.count(for: .phoneScreenshot), 2, "iPhone 截图按根卡片计数")
        try expect(sourceInventory.count(for: .image), 3, "iPhone 截图仍属于图片")
        try expect(sourceInventory.matching(sourceEntries, filter: .phoneScreenshot, query: "").count,
                   2, "iPhone 截图只匹配图片和包含图片的分组")
        try expect(sourceInventory.matching(sourceEntries, filter: .phoneScreenshot, query: "ordinary").count,
                   0, "来源名称不能让文字混入截图分类")
        guard link.webURL?.absoluteString == "https://example.com/path?q=1",
              ClipboardEntry.webURL(from: "javascript:alert(1)") == nil,
              ClipboardEntry.webURL(from: "https://") == nil,
              ClipboardEntry.webURL(from: "http://example.com") != nil else {
            throw Failure.unexpected("仅有效 HTTP(S) 链接可打开")
        }
        print("ClipboardFilterSmoke passed")
    }

    static func entry(
        _ kind: ClipboardEntry.Kind, _ text: String?, fileName: String? = nil
    ) -> ClipboardEntry {
        var result = ClipboardEntry(
            id: UUID(), createdAt: Date(), firstCopiedAt: nil, copyCount: nil,
            kind: kind, text: text, imageFileName: nil, imagePasteboardType: nil,
            digest: UUID().uuidString, byteCount: text?.utf8.count ?? 0
        )
        result.fileName = fileName
        return result
    }

    static func expect(_ actual: Int, _ expected: Int, _ name: String) throws {
        guard actual == expected else {
            throw Failure.unexpected("\(name): expected \(expected), got \(actual)")
        }
    }
}
