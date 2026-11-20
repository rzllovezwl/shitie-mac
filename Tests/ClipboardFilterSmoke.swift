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
        var image = entry(.image, nil)
        image.ocrText = "照片中的专属编号 ZX-2048"
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
        try expect(inventory.matching(entries, filter: .image, query: "ZX-2048").count,
                   1, "图片应能按手动识别出的文字搜索")
        var phoneScreenshot = entry(.image, nil)
        phoneScreenshot.sourceAppName = "iPhone 截图"
        var otherImage = entry(.image, nil)
        otherImage.sourceAppName = "微信"
        var mislabeledText = entry(.text, "ordinary text")
        mislabeledText.sourceAppName = "iPhone 截图"
        var phoneGroupMember = entry(.image, nil)
        phoneGroupMember.sourceAppName = "iPhone 截图"
        phoneGroupMember.ocrText = "群组截图里的文字"
        var group = entry(.group, nil)
        group.groupMemberIDs = [phoneGroupMember.id]
        group.groupMembers = [phoneGroupMember]
        let sourceEntries = [phoneScreenshot, otherImage, mislabeledText, group]
        let sourceInventory = ClipboardFilterInventory(entries: sourceEntries)
        let mainFavoriteID = UUID()
        let mainFavoriteTab = ClipboardShelfNavigation.Tab.favoriteCategory(mainFavoriteID)
        var favorite = plain
        favorite.isFavorite = true
        favorite.favoriteCategoryID = mainFavoriteID
        var favoriteGroup = group
        favoriteGroup.groupMembers[0].isFavorite = true
        favoriteGroup.groupMembers[0].favoriteCategoryID = mainFavoriteID
        favoriteGroup.groupMembers.append(json)
        favoriteGroup.groupMemberIDs = favoriteGroup.groupMembers.map(\.id)
        let favoritesInventory = ClipboardFilterInventory(entries: [favorite, rich, favoriteGroup])
        try expect(favoritesInventory.count(for: .favorites), 2, "收藏包含已收藏的组内卡片")
        try expect(favoritesInventory.matching([favorite, rich, favoriteGroup], filter: .favorites, query: "Notes").count,
                   1, "收藏筛选内搜索来源")
        try expect(favoritesInventory.matching([favorite, rich, favoriteGroup], filter: .favorites, query: "群组截图").count,
                   1, "组内收藏按识别文字搜索")
        let favoriteTypes = ClipboardFilterInventory(entries: [favorite, rich, favoriteGroup], tab: mainFavoriteTab)
        try expect(favoriteTypes.count(for: .all), 2, "收藏分类只统计有收藏内容的卡片")
        try expect(favoriteTypes.count(for: .code), 0, "收藏分类排除组内未收藏的内容")
        try expect(favoriteTypes.count(for: .phoneScreenshot), 1, "收藏分类保留组内已收藏的截图")
        try expect(sourceInventory.count(for: .phoneScreenshot), 2, "iPhone 截图按根卡片计数")
        try expect(sourceInventory.count(for: .image), 3, "iPhone 截图仍属于图片")
        try expect(sourceInventory.matching(sourceEntries, filter: .phoneScreenshot, query: "").count,
                   2, "iPhone 截图只匹配图片和包含图片的分组")
        try expect(sourceInventory.matching(sourceEntries, filter: .phoneScreenshot, query: "ordinary").count,
                   0, "来源名称不能让文字混入截图分类")
        try expect(sourceInventory.matching(sourceEntries, filter: .phoneScreenshot, query: "群组截图").count,
                   1, "分组内图片的识别文字应可搜索")

        var noTextImage = entry(.image, nil)
        noTextImage.ocrText = ""
        let imageScope = ClipboardImageSearchScope(filter: .image, date: nil, tab: .history)
        let pendingImages = ClipboardFilterInventory.unrecognizedImages(in: entries + [noTextImage],
                                                                       scope: imageScope)
        guard pendingImages.map(\.id) == [imageFile.id] else {
            throw Failure.unexpected("搜索应跳过已有识别结果和已确认没有文字的图片")
        }
        let searchDate = Date(timeIntervalSince1970: 1_800_000_000)
        var navigation = ClipboardShelfNavigation()
        let historyFilters = ClipboardShelfNavigation.Filters(query: "report", type: .files, date: searchDate)
        let favoriteFilters = ClipboardShelfNavigation.Filters(query: "截图", type: .image, date: nil)
        guard navigation.tab == .history, navigation.filters == .init() else {
            throw Failure.unexpected("打开面板时默认显示未筛选的历史")
        }
        navigation.filters = historyFilters
        navigation.tab = mainFavoriteTab
        guard navigation.filters == .init() else {
            throw Failure.unexpected("首次打开收藏不应带入历史筛选")
        }
        navigation.filters = favoriteFilters
        navigation.tab = .history
        guard navigation.filters == historyFilters else {
            throw Failure.unexpected("返回历史后应保留关键词、类型和日期")
        }
        navigation.tab = mainFavoriteTab
        guard navigation.filters == favoriteFilters else {
            throw Failure.unexpected("返回收藏后应保留收藏筛选")
        }

        var eligible = phoneScreenshot
        eligible.recordedAt = [searchDate]
        var olderImage = phoneGroupMember
        olderImage.ocrText = nil
        olderImage.recordedAt = [searchDate.addingTimeInterval(-172_800)]
        var outsideFavorite = entry(.image, nil)
        outsideFavorite.sourceAppName = "iPhone 截图"
        outsideFavorite.recordedAt = [searchDate]
        var scopedGroup = group
        scopedGroup.isFavorite = true
        scopedGroup.favoriteCategoryID = mainFavoriteID
        scopedGroup.groupMembers = [olderImage, eligible]
        scopedGroup.groupMemberIDs = scopedGroup.groupMembers.map(\.id)
        let dayScope = ClipboardImageSearchScope(filter: .phoneScreenshot, date: searchDate, tab: mainFavoriteTab)
        let dayImages = ClipboardFilterInventory.unrecognizedImages(
            in: [outsideFavorite, scopedGroup, scopedGroup], scope: dayScope
        )
        guard dayImages.map(\.id) == [eligible.id] else {
            throw Failure.unexpected("图片识别应同时遵循日期、来源分类和收藏，并只安排一次")
        }
        let categoryID = UUID()
        let categoryTab = ClipboardShelfNavigation.Tab.favoriteCategory(categoryID)
        favoriteGroup.groupMembers[0].favoriteCategoryID = categoryID
        favoriteGroup.groupMembers[0].recordedAt = [searchDate]
        let organized = [favorite, rich, favoriteGroup]
        let categoryTypes = ClipboardFilterInventory(entries: organized, tab: categoryTab)
        try expect(categoryTypes.count(for: .all), 1, "自定义分类只显示自己的收藏卡片")
        try expect(categoryTypes.matching(organized, filter: .image, query: "群组截图",
                                          date: searchDate, tab: categoryTab).count, 1, "分类内可按日期和 OCR 搜索")
        try expect(categoryTypes.matching(organized, filter: .image, query: "群组截图",
                                          date: searchDate, tab: mainFavoriteTab).count, 0, "分类不能包含其他分类的卡片")
        try expect(categoryTypes.dailyCounts(organized, filter: .image, query: "群组截图",
                                             tab: categoryTab)[Calendar.current.startOfDay(for: searchDate)] ?? 0,
                   1, "日历数量应遵守收藏分类和搜索范围")
        scopedGroup.favoriteCategoryID = categoryID
        let categoryScope = ClipboardImageSearchScope(filter: .phoneScreenshot, date: searchDate, tab: categoryTab)
        let scopedIDs = ClipboardFilterInventory.unrecognizedImages(in: [scopedGroup], scope: categoryScope).map(\.id)
        guard scopedIDs == [eligible.id] else { throw Failure.unexpected("OCR 应只安排当前分类内的候选") }
        navigation.tab = categoryTab
        guard navigation.filters == .init() else { throw Failure.unexpected("新分类应有独立筛选") }
        navigation.filters.query = "项目"
        navigation.removeCategory(categoryID)
        guard navigation.tab == .history, navigation.filters == historyFilters else {
            throw Failure.unexpected("删除当前分类应返回历史并恢复它的筛选")
        }
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
