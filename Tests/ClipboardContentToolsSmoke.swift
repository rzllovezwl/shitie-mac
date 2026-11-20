import Foundation

enum ClipboardContentToolsSmokeError: Error {
    case failed(String)
}

@main
struct ClipboardContentToolsSmoke {
    static func main() throws {
        try check(ClipboardContentTools.transform(
            "\nA\r\n \r\n\r\nB\n\n", operation: .collapseBlankLines
        ).text == "A\n\nB", "空行清理应保留一行间隔")
        try check(ClipboardContentTools.transform(
            " A\tB\u{3000}C\u{00A0}D\n E\r\nF ", operation: .removeSpaces
        ).text == "ABCD\nE\r\nF", "去除空格应保留原来的换行")
        try check(ClipboardContentTools.transform("aBc 你好", operation: .uppercase).text == "ABC 你好",
                  "大写转换失败")
        try check(ClipboardContentTools.transform("aBc 你好", operation: .lowercase).text == "abc 你好",
                  "小写转换失败")

        let pretty = ClipboardContentTools.transform(#"{"name":"张三","count":2}"#,
                                                     operation: .prettyJSON)
        try check(pretty.text?.contains("\n") == true && pretty.text?.contains("张三") == true,
                  "JSON 格式化失败")
        try check(ClipboardContentTools.transform("{broken", operation: .prettyJSON).error != nil,
                  "无效 JSON 应给出错误")

        let source = "你好 &<>\"'"
        let base64 = ClipboardContentTools.transform(source, operation: .base64Encode).text ?? ""
        try check(ClipboardContentTools.transform(base64, operation: .base64Decode).text == source,
                  "Base64 往返转换失败")
        try check(ClipboardContentTools.transform("%%%", operation: .base64Decode).error != nil,
                  "无效 Base64 不应生成结果")
        let encodedURL = ClipboardContentTools.transform("你好 +&", operation: .urlEncode).text ?? ""
        try check(encodedURL.contains("%20") && encodedURL.contains("%2B") &&
                  ClipboardContentTools.transform(encodedURL, operation: .urlDecode).text == "你好 +&",
                  "URL 百分号编码往返失败")
        try check(ClipboardContentTools.transform("%XX", operation: .urlDecode).error != nil,
                  "无效百分号编码应给出错误")
        let html = ClipboardContentTools.transform(source, operation: .htmlEncode).text ?? ""
        try check(ClipboardContentTools.transform(html, operation: .htmlDecode).text == source,
                  "HTML 实体编码往返失败")
        try check(ClipboardContentTools.transform("&#x4F60;&#22909;", operation: .htmlDecode).text
                  == "你好", "HTML 数字实体解码失败")

        try check(ParsedColor.parse("#f80")?.hex == "#FF8800", "短 HEX 颜色解析失败")
        try check(ParsedColor.parse("#33669980")?.hex == "#33669980", "透明 HEX 颜色解析失败")
        try check(ParsedColor.parse("rgb(255, 128, 0)")?.hex == "#FF8000", "RGB 颜色解析失败")
        try check(ParsedColor.parse("rgba(255, 0, 0, 50%)")?.hex == "#FF000080",
                  "RGBA 颜色解析失败")
        try check(ParsedColor.parse("rgb(300, 0, 0)") == nil, "超出范围的颜色应拒绝")

        let url = "https://example.com/path?utm_source=mail&token=a%2Bb&fbclid=xyz&ref=important#part"
        guard let cleaner = URLQueryCleaner(url) else {
            throw ClipboardContentToolsSmokeError.failed("链接解析失败")
        }
        try check(cleaner.suggestedRemovalIDs == Set([0, 2]),
                  "只应默认选择明确的跟踪参数")
        try check(cleaner.cleanedURL(removing: cleaner.suggestedRemovalIDs)
                  == "https://example.com/path?token=a%2Bb&ref=important#part",
                  "链接清理应原样保留功能参数和片段")
        try check(cleaner.cleanedURL(removing: [0])
                  == "https://example.com/path?token=a%2Bb&fbclid=xyz&ref=important#part",
                  "用户取消勾选的跟踪参数应保留")
        let signed = URLQueryCleaner("https://a.example/?sig=AB%2FCD&utm%5Fmedium=ad")!
        try check(signed.suggestedRemovalIDs == Set([1]) &&
                  signed.cleanedURL(removing: [1]) == "https://a.example/?sig=AB%2FCD",
                  "已编码的参数名可识别，签名应原样保留")
        try check(URLQueryCleaner("https://a.example/?utm_source=x")?
                  .cleanedURL(removing: [0]) == "https://a.example/",
                  "删除唯一参数后不应保留问号")
        try check(URLQueryCleaner("hello world") == nil, "非网页链接不应进入清理器")
        print("Clipboard content tools smoke test passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool,
                              _ message: String) throws {
        if !condition() { throw ClipboardContentToolsSmokeError.failed(message) }
    }
}
