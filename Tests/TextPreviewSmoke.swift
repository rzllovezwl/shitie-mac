import AppKit
import Foundation

private enum PreviewTestError: Error { case failed(String) }

@main
struct TextPreviewSmoke {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let raw = "    let name = \"ClipHoook\"\n\tprint(name)\n\n"
        let files = RichTextSourceFiles(rtf: nil, html: nil, rtfd: nil)
        let plain = await TextPreviewRenderer.render(mode: .plain, raw: raw, files: files)
        try check(plain.text.string == raw, "原文预览改变了缩进或末尾换行")

        let markdown = await TextPreviewRenderer.render(
            mode: .markdown, raw: "# 标题\n\n**加粗**、`代码`\n- 项目", files: files
        )
        try check(markdown.text.string == "标题\n\n加粗、代码\n•  项目", "Markdown 预览丢失段落或内联内容")
        let headingFont = markdown.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check((headingFont?.pointSize ?? 0) > 13, "Markdown 标题没有字号区分")
        let boldOffset = (markdown.text.string as NSString).range(of: "加粗").location
        let boldFont = markdown.text.attribute(.font, at: boldOffset, effectiveRange: nil) as? NSFont
        try check(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true, "Markdown 加粗未渲染")

        let code = await TextPreviewRenderer.render(mode: .code, raw: raw, files: files, language: "Swift")
        try check(code.text.string == raw, "代码预览改写了原文")
        let keywordColor = code.text.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        try check(keywordColor == .systemPurple, "代码关键字没有高亮")
        try check(["HTML", "Objective-C", "Java", "Kotlin", "Go", "Rust", "C", "C++", "C#", "PHP", "Ruby", "Dart"]
            .allSatisfy(TextPreviewRenderer.codeLanguages.contains), "代码语言菜单缺少常用语言")
        let htmlSource = "<main class=\"card\"><h1>标题</h1></main>"
        let htmlCode = await TextPreviewRenderer.render(
            mode: .code, raw: htmlSource, files: files, language: "HTML"
        )
        try check(htmlCode.text.string == htmlSource, "HTML 预览改写了代码")
        try check((htmlCode.text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            == .systemBlue, "HTML 标签没有高亮")

        let richSource = NSMutableAttributedString(string: "红色标题\n正文", attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .bold),
            .foregroundColor: NSColor.systemRed
        ])
        let rtf = try richSource.data(from: NSRange(location: 0, length: richSource.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtfURL = folder.appendingPathComponent("sample.rtf")
        try rtf.write(to: rtfURL)
        let richFiles = RichTextSourceFiles(rtf: rtfURL, html: nil, rtfd: nil)
        try check(TextPreviewMode.suggested(for: .swift, hasRichText: true) == .code,
                  "附带富文本的代码未默认打开代码预览")
        try check(TextPreviewMode.suggested(for: .markdown, hasRichText: true) == .markdown,
                  "附带富文本的 Markdown 未默认打开排版预览")
        let renderedMarkdown = await TextPreviewRenderer.render(
            mode: .markdown, raw: richSource.string, files: richFiles
        )
        let renderedFont = renderedMarkdown.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check(renderedMarkdown.text.string == richSource.string &&
                  (renderedFont?.pointSize ?? 0) == 18 && !renderedMarkdown.actualRichText,
                  "从 Markdown 预览复制的富文本未保留标题排版")
        let markdownSource = "## 标题\n\n**重点**"
        let sourcePreview = await TextPreviewRenderer.render(
            mode: .markdown, raw: markdownSource, files: richFiles
        )
        try check(sourcePreview.text.string == "标题\n\n重点",
                  "复制 Markdown 源码时未按标记排版")
        let sourceMode = TextPreviewMode.original.renderingMode(for: .markdown, hasRichText: true)
        let sourceText = await TextPreviewRenderer.render(
            mode: sourceMode, raw: markdownSource, files: richFiles
        )
        try check(sourceText.text.string == markdownSource,
                  "Markdown 原格式页没有显示实际复制的标记")
        let rich = await TextPreviewRenderer.render(
            mode: .original, raw: richSource.string,
            files: RichTextSourceFiles(rtf: rtfURL, html: nil, rtfd: nil)
        )
        try check(rich.actualRichText && rich.text.string == richSource.string, "RTF 原格式预览失败")
        let richFont = rich.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check((richFont?.pointSize ?? 0) == 18, "RTF 字号丢失")
        let cardRich = await TextPreviewRenderer.render(
            mode: .original, raw: richSource.string,
            files: RichTextSourceFiles(rtf: rtfURL, html: nil, rtfd: nil),
            maximumCharacters: 3
        )
        try check(cardRich.actualRichText && cardRich.text.string == "红色标", "卡片预览未限制片段长度")
        let cardFont = cardRich.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try check((cardFont?.pointSize ?? 0) == 18, "卡片片段丢失原格式")
        let format = TextPreviewView.Coordinator.describe(rich.text.attributes(at: 0, effectiveRange: nil))
        try check(format.contains("18 pt") && format.contains("加粗") && format.contains("文字 #"),
                  "选中文字的字号、字重或颜色说明缺失")

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw PreviewTestError.failed("无法创建内嵌图片测试数据") }
        let sampleColor = NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        for y in 0..<8 {
            for x in 0..<8 { bitmap.setColor(sampleColor, atX: x, y: y) }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewTestError.failed("无法生成内嵌 PNG")
        }
        let pictureHex = png.map { String(format: "%02x", $0) }.joined()
        // An unsupported Office destination makes AppKit drop the native
        // attachment even though the PNG bytes remain inside the RTF.
        let pictureRTF = "{\\rtf1\\ansi Office text\\par {\\*\\officepicture{\\pict\\pngblip\n\(pictureHex)\n}}}"
        let pictureURL = folder.appendingPathComponent("office-picture.rtf")
        try Data(pictureRTF.utf8).write(to: pictureURL)
        guard let nativeRTF = try? NSAttributedString(
            data: Data(pictureRTF.utf8),
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { throw PreviewTestError.failed("无法解析测试用 Office RTF") }
        var nativeAttachments = 0
        nativeRTF.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: nativeRTF.length)
        ) { value, _, _ in
            if value != nil { nativeAttachments += 1 }
        }
        try check(nativeAttachments == 0, "测试夹具未覆盖 AppKit 丢失图片的场景")
        let pictureFiles = RichTextSourceFiles(rtf: pictureURL, html: nil, rtfd: nil)
        let picturePreview = await TextPreviewRenderer.render(
            mode: .original, raw: "Office text", files: pictureFiles
        )
        var pictureAttachments = 0
        picturePreview.text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: picturePreview.text.length)
        ) { value, _, _ in
            if value != nil { pictureAttachments += 1 }
        }
        try check(picturePreview.actualRichText && picturePreview.text.string.contains("Office text") &&
                  pictureAttachments == 1, "Word/WPS RTF 内嵌图片未在原格式预览中显示")
        let pictureCard = await TextPreviewRenderer.render(
            mode: .original, raw: "Office text", files: pictureFiles, maximumCharacters: 1_200
        )
        var cardAttachments = 0
        pictureCard.text.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: pictureCard.text.length)
        ) { value, _, _ in
            if value != nil { cardAttachments += 1 }
        }
        try check(pictureCard.text.string.contains("Office text") && cardAttachments == 1,
                  "带内嵌图片的富文本卡片没有同时显示文字和图片")

        let safeHTML = folder.appendingPathComponent("safe.html")
        try Data("<html><body><strong>安全预览</strong></body></html>".utf8).write(to: safeHTML)
        let htmlPreview = await TextPreviewRenderer.render(
            mode: .original, raw: "安全预览",
            files: RichTextSourceFiles(rtf: nil, html: safeHTML, rtfd: nil)
        )
        try check(htmlPreview.actualRichText && htmlPreview.text.string.contains("安全预览"),
                  "安全 HTML 未显示原格式")
        let simpleTitle = (htmlPreview.text.string as NSString).range(of: "安全预览").location
        try check((htmlPreview.text.attribute(.foregroundColor, at: simpleTitle, effectiveRange: nil) as? NSColor) == .black,
                  "未指定颜色的文档文字应在白色纸张上显示为黑色")

        let officeHTML = folder.appendingPathComponent("office.html")
        let officeSource = """
            <html><head><style>p.MsoNormal { font-size: 20pt; color: #B00020; }</style></head>
            <body><table><tr><td><p class="MsoNormal">文档标题</p></td></tr></table></body></html>
            """
        try Data(officeSource.utf8).write(to: officeHTML)
        let officePreview = await TextPreviewRenderer.render(
            mode: .original, raw: "文档标题",
            files: RichTextSourceFiles(rtf: nil, html: officeHTML, rtfd: nil)
        )
        try check(officePreview.actualRichText && officePreview.text.string.contains("文档标题"),
                  "带内嵌样式表的 Office HTML 错误退回原文")
        let officeTitle = (officePreview.text.string as NSString).range(of: "文档标题").location
        try check((officePreview.text.attribute(.foregroundColor, at: officeTitle, effectiveRange: nil) as? NSColor) != nil,
                  "原格式预览的文字没有可见颜色")
        let officeCard = await TextPreviewRenderer.render(
            mode: .original, raw: "文档标题",
            files: RichTextSourceFiles(rtf: nil, html: officeHTML, rtfd: nil),
            maximumCharacters: 3
        )
        try check(officeCard.actualRichText && officeCard.text.string.hasPrefix("文档标"),
                  "带表格的 Office 内容无法生成卡片原格式片段")

        let unsafeHTML = folder.appendingPathComponent("unsafe.html")
        try Data("<img src='https://example.com/pixel'>测试".utf8).write(to: unsafeHTML)
        let fallback = await TextPreviewRenderer.render(
            mode: .original, raw: "测试", files: RichTextSourceFiles(rtf: nil, html: unsafeHTML, rtfd: nil)
        )
        try check(!fallback.actualRichText && fallback.text.string == "测试" && fallback.notice != nil,
                  "含外部资源的 HTML 没有退回原文")

        let externalCSS = folder.appendingPathComponent("external-css.html")
        try Data("<style>p { background: url(https://example.com/pixel) }</style><p>测试</p>".utf8)
            .write(to: externalCSS)
        let cssFallback = await TextPreviewRenderer.render(
            mode: .original, raw: "测试",
            files: RichTextSourceFiles(rtf: nil, html: externalCSS, rtfd: nil)
        )
        try check(!cssFallback.actualRichText && cssFallback.text.string == "测试",
                  "带外部资源的 CSS 不应被解析")

        let long = String(repeating: "文", count: TextPreviewRenderer.maximumPreviewCharacters + 5)
        let capped = await TextPreviewRenderer.render(mode: .plain, raw: long, files: files)
        try check(capped.text.length == TextPreviewRenderer.maximumPreviewCharacters && capped.notice != nil,
                  "长文本未限制预览长度")
        print("TextPreviewSmoke passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PreviewTestError.failed(message) }
    }
}
