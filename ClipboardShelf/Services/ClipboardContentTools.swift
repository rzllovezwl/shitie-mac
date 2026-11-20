import Foundation

enum TextToolOperation: String, CaseIterable, Identifiable, Sendable {
    case collapseBlankLines
    case removeSpaces
    case plainText
    case uppercase
    case lowercase
    case prettyJSON
    case base64Encode
    case base64Decode
    case urlEncode
    case urlDecode
    case htmlEncode
    case htmlDecode
    case colorPreview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .collapseBlankLines: "去多余空行"
        case .removeSpaces: "去除空格"
        case .plainText: "去富文本格式"
        case .uppercase: "转大写"
        case .lowercase: "转小写"
        case .prettyJSON: "JSON 格式化"
        case .base64Encode: "Base64 编码"
        case .base64Decode: "Base64 解码"
        case .urlEncode: "URL 编码"
        case .urlDecode: "URL 解码"
        case .htmlEncode: "HTML 实体编码"
        case .htmlDecode: "HTML 实体解码"
        case .colorPreview: "颜色值预览"
        }
    }

    var category: String {
        switch self {
        case .collapseBlankLines, .removeSpaces, .plainText, .uppercase, .lowercase: "文本清理"
        case .prettyJSON, .base64Encode, .base64Decode, .urlEncode, .urlDecode,
             .htmlEncode, .htmlDecode, .colorPreview: "开发辅助"
        }
    }

    static func suggested(for text: String, classification: ClipboardTextClassification) -> Self {
        if classification == .json { return .prettyJSON }
        if ParsedColor.parse(text) != nil { return .colorPreview }
        return .collapseBlankLines
    }
}

struct TextToolOutput: Sendable {
    let text: String?
    let error: String?
    let color: ParsedColor?

    init(text: String? = nil, error: String? = nil, color: ParsedColor? = nil) {
        self.text = text
        self.error = error
        self.color = color
    }
}

enum ClipboardContentTools {
    private static let maximumStructuredInputBytes = 8 * 1_024 * 1_024

    static func transform(_ text: String, operation: TextToolOperation) -> TextToolOutput {
        if ![.collapseBlankLines, .removeSpaces, .plainText, .uppercase, .lowercase].contains(operation),
           text.utf8.count > maximumStructuredInputBytes {
            return TextToolOutput(error: "这项处理支持最多 8 MB 文本；请先选中需要处理的部分。")
        }
        switch operation {
        case .collapseBlankLines:
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            var result: [String] = []
            var previousWasBlank = false
            for line in normalized.components(separatedBy: "\n") {
                let blank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if blank {
                    guard !result.isEmpty, !previousWasBlank else { continue }
                    result.append("")
                } else {
                    result.append(line)
                }
                previousWasBlank = blank
            }
            while result.last == "" { result.removeLast() }
            return TextToolOutput(text: result.joined(separator: "\n"))
        case .removeSpaces:
            // Remove horizontal whitespace only; line breaks still separate
            // paragraphs, and the source card is never rewritten.
            var result = String.UnicodeScalarView()
            let horizontalWhitespace = CharacterSet.whitespaces
            for scalar in text.unicodeScalars where !horizontalWhitespace.contains(scalar) {
                result.append(scalar)
            }
            return TextToolOutput(text: String(result))
        case .plainText: return TextToolOutput(text: text)
        case .uppercase: return TextToolOutput(text: text.uppercased())
        case .lowercase: return TextToolOutput(text: text.lowercased())
        case .prettyJSON:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let output = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]
                  ), let string = String(data: output, encoding: .utf8) else {
                return TextToolOutput(error: "不是有效的 JSON，请检查括号、引号和逗号。")
            }
            return TextToolOutput(text: string)
        case .base64Encode:
            return TextToolOutput(text: Data(text.utf8).base64EncodedString())
        case .base64Decode:
            let compact = text.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: compact),
                  let decoded = String(data: data, encoding: .utf8) else {
                return TextToolOutput(error: "不是有效的 Base64 UTF-8 文本。")
            }
            return TextToolOutput(text: decoded)
        case .urlEncode:
            let bytes = Array(text.utf8)
            let encoded = bytes.map { byte -> String in
                if (65...90).contains(byte) || (97...122).contains(byte) ||
                    (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                    return String(UnicodeScalar(byte))
                }
                return String(format: "%%%02X", byte)
            }.joined()
            return TextToolOutput(text: encoded)
        case .urlDecode:
            guard let decoded = text.removingPercentEncoding else {
                return TextToolOutput(error: "URL 编码不完整；请检查百分号后面的十六进制数字。")
            }
            return TextToolOutput(text: decoded)
        case .htmlEncode:
            let encoded = text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
            return TextToolOutput(text: encoded)
        case .htmlDecode:
            return TextToolOutput(text: decodeHTMLEntities(text))
        case .colorPreview:
            guard let color = ParsedColor.parse(text) else {
                return TextToolOutput(error: "请选择一个 #RGB、#RRGGBB、#RRGGBBAA 或 rgb(a) 颜色值。")
            }
            return TextToolOutput(text: color.hex, color: color)
        }
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        let pattern = #"&(?:#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let result = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "hellip": "…"
        ]
        for match in matches.reversed() {
            let entity = (text as NSString).substring(with: match.range)
            let body = String(entity.dropFirst().dropLast())
            let replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16)
                    .flatMap(UnicodeScalar.init).map(String.init)
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst(), radix: 10)
                    .flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = named[body]
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}

struct URLQueryParameter: Identifiable, Sendable {
    let id: Int
    let name: String
    let value: String?
    let suggestedForRemoval: Bool
}

/// Rebuilds only the query, preserving the exact encoding, order, path, and
/// fragment of every parameter the user decides to keep.
struct URLQueryCleaner: Sendable {
    let source: String
    let parameters: [URLQueryParameter]
    private let prefix: String
    private let fragment: String
    private let rawSegments: [String]

    init?(_ source: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        let fragmentIndex = source.firstIndex(of: "#") ?? source.endIndex
        let beforeFragment = source[..<fragmentIndex]
        let queryIndex = beforeFragment.firstIndex(of: "?")
        self.source = source
        fragment = String(source[fragmentIndex...])
        if let queryIndex {
            prefix = String(beforeFragment[..<queryIndex])
            rawSegments = String(beforeFragment[beforeFragment.index(after: queryIndex)...])
                .components(separatedBy: "&")
        } else {
            prefix = String(beforeFragment)
            rawSegments = []
        }
        parameters = rawSegments.enumerated().compactMap { index, raw in
            guard !raw.isEmpty else { return nil }
            let pieces = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pieces[0]).removingPercentEncoding ?? String(pieces[0])
            let value = pieces.count > 1
                ? (String(pieces[1]).removingPercentEncoding ?? String(pieces[1])) : nil
            return URLQueryParameter(id: index, name: name, value: value,
                                     suggestedForRemoval: Self.isKnownTrackingParameter(name))
        }
    }

    var suggestedRemovalIDs: Set<Int> {
        Set(parameters.filter(\.suggestedForRemoval).map(\.id))
    }

    func cleanedURL(removing ids: Set<Int>) -> String {
        guard !ids.isEmpty else { return source }
        let remaining = rawSegments.enumerated().compactMap { ids.contains($0.offset) ? nil : $0.element }
        guard remaining.contains(where: { !$0.isEmpty }) else { return prefix + fragment }
        return prefix + "?" + remaining.joined(separator: "&") + fragment
    }

    private static func isKnownTrackingParameter(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("utm_") { return true }
        return ["gclid", "dclid", "fbclid", "msclkid", "gbraid", "wbraid", "yclid",
                "igshid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "vero_id"]
            .contains(lower)
    }
}

struct ParsedColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var hex: String {
        let values = [red, green, blue].map { Int(($0 * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", values[0], values[1], values[2])
        return alpha >= 1 ? base : base + String(format: "%02X", Int((alpha * 255).rounded()))
    }

    var rgba: String {
        "rgba(\(Int((red * 255).rounded())), \(Int((green * 255).rounded())), " +
            "\(Int((blue * 255).rounded())), \(String(format: "%.3g", alpha)))"
    }

    static func parse(_ input: String) -> Self? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            guard [3, 4, 6, 8].contains(digits.count),
                  digits.unicodeScalars.allSatisfy({
                    CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
                  })
            else { return nil }
            let expanded = digits.count <= 4
                ? digits.map { "\($0)\($0)" }.joined() : digits
            let bytes = stride(from: 0, to: expanded.count, by: 2).compactMap { offset -> Double? in
                let start = expanded.index(expanded.startIndex, offsetBy: offset)
                let end = expanded.index(start, offsetBy: 2)
                return UInt8(expanded[start..<end], radix: 16).map { Double($0) / 255 }
            }
            guard bytes.count == expanded.count / 2 else { return nil }
            return Self(red: bytes[0], green: bytes[1], blue: bytes[2],
                        alpha: bytes.count == 4 ? bytes[3] : 1)
        }
        let lower = text.lowercased()
        let hasAlpha = lower.hasPrefix("rgba(")
        guard hasAlpha || lower.hasPrefix("rgb("), text.hasSuffix(")") else { return nil }
        let start = text.index(text.startIndex, offsetBy: hasAlpha ? 5 : 4)
        let parts = text[start..<text.index(before: text.endIndex)]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (hasAlpha ? 4 : 3) else { return nil }
        let channels = parts.prefix(3).compactMap { part -> Double? in
            if part.hasSuffix("%"), let percent = Double(part.dropLast()), (0...100).contains(percent) {
                return percent / 100
            }
            guard let number = Double(part), (0...255).contains(number) else { return nil }
            return number / 255
        }
        guard channels.count == 3 else { return nil }
        let alpha: Double
        if hasAlpha {
            if parts[3].hasSuffix("%"), let percent = Double(parts[3].dropLast()),
               (0...100).contains(percent) {
                alpha = percent / 100
            } else if let value = Double(parts[3]), (0...1).contains(value) {
                alpha = value
            } else { return nil }
        } else {
            alpha = 1
        }
        return Self(red: channels[0], green: channels[1], blue: channels[2], alpha: alpha)
    }
}
