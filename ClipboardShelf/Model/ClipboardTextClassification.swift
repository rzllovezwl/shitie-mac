import Foundation

enum CardPreviewPreference {
    static let enabledKey = "cardFormattedPreviewEnabled"
    static let defaultEnabled = true
}

/// This describes the text's likely syntax, independently of the pasteboard's
/// storage format. Detection only affects labels and previews, never saved data.
enum ClipboardTextClassification: Hashable {
    case plain
    case rich
    case markdown
    case swift
    case json
    case jsonLines
    case yaml
    case xml
    case css
    case sql
    case csv
    case python
    case javaScript
    case typeScript
    case shell
    case html
    case objectiveC
    case java
    case kotlin
    case go
    case rust
    case c
    case cpp
    case cSharp
    case php
    case ruby
    case dart
    case code

    var label: String {
        switch self {
        case .plain: "文本"
        case .rich: "富文本"
        case .markdown: "Markdown"
        case .swift: "Swift 代码"
        case .json: "JSON"
        case .jsonLines: "JSON Lines"
        case .yaml: "YAML"
        case .xml: "XML"
        case .css: "CSS"
        case .sql: "SQL"
        case .csv: "CSV"
        case .python: "Python 代码"
        case .javaScript: "JavaScript 代码"
        case .typeScript: "TypeScript 代码"
        case .shell: "Shell 脚本"
        case .html: "HTML 代码"
        case .objectiveC: "Objective-C 代码"
        case .java: "Java 代码"
        case .kotlin: "Kotlin 代码"
        case .go: "Go 代码"
        case .rust: "Rust 代码"
        case .c: "C 代码"
        case .cpp: "C++ 代码"
        case .cSharp: "C# 代码"
        case .php: "PHP 代码"
        case .ruby: "Ruby 代码"
        case .dart: "Dart 代码"
        case .code: "代码"
        }
    }

    var codeLanguage: String? {
        switch self {
        case .swift: "Swift"
        case .json: "JSON"
        case .jsonLines: "JSON"
        case .yaml: "YAML"
        case .xml: "XML"
        case .css: "CSS"
        case .sql: "SQL"
        case .csv: "CSV"
        case .python: "Python"
        case .javaScript: "JavaScript"
        case .typeScript: "TypeScript"
        case .shell: "Shell"
        case .html: "HTML"
        case .objectiveC: "Objective-C"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .go: "Go"
        case .rust: "Rust"
        case .c: "C"
        case .cpp: "C++"
        case .cSharp: "C#"
        case .php: "PHP"
        case .ruby: "Ruby"
        case .dart: "Dart"
        case .code: "自动"
        default: nil
        }
    }

    static func detect(
        text: String, hasRichText: Bool,
        sourceAppBundleID: String? = nil, sourceAppName: String? = nil
    ) -> Self {
        // Inspect a bounded prefix. A pasted JSON export can be tens of MB;
        // parsing it for every card redraw would stall resizing and scrolling.
        let sampleLimit = 8_192
        let sample = String(text.prefix(sampleLimit))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hasRichText ? .rich : .plain }

        if trimmed.hasPrefix("#!") && matches(trimmed, #"^#![^\n]*(?:/|\b)(?:ba|z|fi)?sh\b"#) {
            return .shell
        }
        if matches(trimmed, #"(?i)^(?:<!doctype\s+html\b|<(?:html|head|body|main|nav|header|footer|div|p|table|section|article)\b)"#) {
            return .html
        }
        if trimmed.hasPrefix("<?xml") ||
            matches(trimmed, #"(?s)^<(?:svg|rss|feed|[A-Za-z][\w.-]*:[\w.-]+)\b[^>]*>"#) ||
            matches(trimmed, #"(?s)^<([A-Za-z][\w.-]*)\b[^>]*>.*</\1>"#) {
            return .xml
        }
        if let jsonType = jsonClassification(text: text, sample: trimmed, sampleLimit: sampleLimit) {
            return jsonType
        }

        // A complete Markdown fence or heading is strong evidence. A single
        // bullet is not: Office documents commonly contain ordinary lists.
        let comesFromMWeb = [sourceAppBundleID, sourceAppName]
            .compactMap { $0?.localizedLowercase }
            .contains { $0.contains("mweb") }
        // MWeb can put an HTML/RTF representation on the pasteboard even when
        // the editor is showing Markdown source. Its numbered headings alone
        // are ambiguous, so only use this hint for a known Markdown editor.
        let mwebNumberedHeading = comesFromMWeb &&
            matches(sample, #"(?m)^\s{0,3}\d+(?:\.\d+)*[.、]\s+\S[^\n]{0,100}$"#)
        if mwebNumberedHeading ||
            matches(sample, #"(?m)^\s{0,3}(?:#{1,6}\s+\S|```\w*\s*$|~~~\w*\s*$)"#) ||
            (matches(sample, #"(?m)^\s{0,3}(?:[-*+]\s+|\d+\.\s+)"#) &&
             (matches(sample, #"(?m)(?:\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\n]+\))"#) ||
              (!hasRichText && matchCount(sample, #"(?m)^\s{0,3}(?:[-*+]\s+|\d+\.\s+)"#) >= 2))) ||
            (!hasRichText && matches(sample, #"(?:\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\n]+\))"#)) {
            return .markdown
        }

        let yamlKeyCount = matchCount(sample, #"(?m)^\s{0,6}[A-Za-z_][\w.-]*:\s*(?:\S.*)?$"#)
        if (sample.hasPrefix("---") && yamlKeyCount >= 2 || yamlKeyCount >= 3) &&
            !sample.contains("{") {
            return .yaml
        }
        if matches(sample, #"(?im)^\s*(?:SELECT\s+.+?\s+FROM\b|INSERT\s+INTO\b|CREATE\s+TABLE\b|UPDATE\s+\w+\s+SET\b|DELETE\s+FROM\b|WITH\s+\w+\s+AS\s*\()"#) {
            return .sql
        }
        if matches(sample, #"(?m)^\s*(?:[.#][A-Za-z][\w:.-]*|(?:body|html|h[1-6]|div|p|a|button|:root)|@media\s+[^{}]+)\s*\{"#) &&
            matches(sample, #"(?m)(?:^|[;{])\s*(?:color|display|background(?:-\w+)?|font(?:-\w+)?|margin(?:-\w+)?|padding(?:-\w+)?|border(?:-\w+)?)\s*:\s*[^{}\n]+;"#) {
            return .css
        }
        if matches(sample, #"(?m)^\s*(?:export\s+)?(?:interface\s+\w+\s*\{|type\s+\w+(?:<[^>]+>)?\s*=|import\s+type\s+|(?:const|let)\s+\w+\s*:\s*(?:string|number|boolean|Promise<|[\w.]+(?:<[^>]+>)?\s*=.*=>))"#) {
            return .typeScript
        }

        // Prefer signatures that identify one language over shared words such
        // as class, import, function and return. Short ambiguous fragments
        // remain generic instead of being assigned an incorrect language.
        if sample.contains("<?php") && matches(sample, #"(?i)^<\?php\b"#) {
            return .php
        }
        if sample.contains("@interface") || sample.contains("@implementation") ||
            sample.contains("#import") || trimmed.hasPrefix("- (") ||
            trimmed.hasPrefix("+ (") {
            if matches(sample, #"(?m)^\s*(?:@(?:interface|implementation|protocol|property|end)\b|#import\s*[<\"]|[-+]\s*\([^)]*\)\s*\w+)"#) {
                return .objectiveC
            }
        }
        if sample.contains("using System") || sample.contains("namespace ") ||
            sample.contains("Console.WriteLine") {
            if matches(sample, #"(?m)^\s*(?:using\s+System(?:\.\w+)*\s*;|namespace\s+[\w.]+\s*(?:\{|;)|\[\s*(?:HttpGet|HttpPost|Serializable)\b|Console\.WriteLine\s*\()"#) {
                return .cSharp
            }
        }
        if sample.contains("import 'package:") || sample.contains("import \"package:") ||
            sample.contains("void main(") {
            if matches(sample, #"(?m)^\s*(?:import\s+['\"](?:package:|dart:)[^'\"]+['\"]\s*;|void\s+main\s*\(\s*\)\s*\{|class\s+\w+\s+extends\s+(?:StatelessWidget|StatefulWidget)\b)"#) {
                return .dart
            }
        }
        if sample.contains("package ") || sample.contains("func main(") ||
            sample.contains(":=") {
            if matches(sample, #"(?m)^\s*(?:package\s+\w+\s*$|func\s+(?:\(\s*\w+\s+\*?\w+\s*\)\s*)?\w+\s*\([^)]*\)\s*(?:\([^)]*\)|[\w*\[\]]+)?\s*\{|\w+\s*:=\s*.+)"#) {
                return .go
            }
        }
        if sample.contains("fn ") || sample.contains("use std::") || sample.contains("let mut ") {
            if matches(sample, #"(?m)^\s*(?:(?:pub\s+)?fn\s+\w+\s*\([^)]*\)\s*(?:->\s*[^{}]+)?\s*\{|(?:pub\s+)?(?:struct|enum|trait|impl)\s+\w+\s*\{|use\s+std::|let\s+mut\s+\w+\s*=)"#) {
                return .rust
            }
        }
        if sample.contains("#include") || sample.contains("std::") || sample.contains("template<") {
            if matches(sample, #"(?m)^\s*(?:#include\s*<(?:iostream|vector|string|memory|algorithm|map|unordered_map)>|using\s+namespace\s+std\s*;|template\s*<\s*(?:typename|class)\b)"#) ||
                sample.contains("std::") {
                return .cpp
            }
        }
        if sample.contains("fun ") || sample.contains("data class ") ||
            sample.contains("companion object") {
            if matches(sample, #"(?m)^\s*(?:fun\s+\w+\s*\([^)]*\)\s*(?::\s*[\w<>?]+)?\s*(?:\{|=)|data\s+class\s+\w+\s*\(|(?:private\s+)?val\s+\w+\s*:\s*[\w<>?]+\s*=|companion\s+object\s*\{)"#) {
                return .kotlin
            }
        }
        if sample.contains("package ") || sample.contains("public class ") ||
            sample.contains("public static void main") {
            if matches(sample, #"(?m)^\s*(?:package\s+[\w.]+\s*;|import\s+java\.[\w.*]+\s*;|public\s+(?:final\s+)?class\s+\w+\s*\{|public\s+static\s+void\s+main\s*\()"#) {
                return .java
            }
        }
        if sample.contains("#include") &&
            matches(sample, #"(?m)^\s*#include\s*[<\"][^>\"\n]+[>\"]"#) {
            return .c
        }
        if sample.contains("def ") && sample.contains("\nend") &&
            matches(sample, #"(?m)^\s*def\s+\w+(?:\([^)]*\))?\s*$"#) &&
            matches(sample, #"(?m)^\s*end\s*$"#) {
            return .ruby
        }

        if matches(sample, #"(?m)^\s*(?:@(?:State|Binding|MainActor|Published|Observable)\b|(?:import\s+(?:SwiftUI|AppKit|Combine)\b)|(?:public|private|internal|fileprivate|final|open|static|override|mutating|nonisolated|\s)*\b(?:func|struct|enum|protocol|extension|actor)\s+\w+)"#) ||
            matches(sample, #"\b(?:guard\s+let|if\s+let|try\?|async\s+throws|some\s+View)\b"#) ||
            (matches(sample, #"(?m)^\s*import\s+Foundation\s*$"#) &&
             matches(sample, #"(?m)^\s*(?:let|var)\s+\w+\s*(?::\s*\w+)?\s*="#)) ||
            (sourceAppBundleID == "com.apple.dt.Xcode" &&
             matches(sample, #"(?m)^\s*(?:let|var)\s+\w+\s*(?::\s*\w+)?\s*="#)) {
            return .swift
        }
        if matches(sample, #"(?m)^\s*(?:def\s+\w+\s*\(|class\s+\w+(?:\([^)]*\))?\s*:|from\s+\w+(?:\.\w+)*\s+import\s+)"#) {
            return .python
        }
        if matches(sample, #"(?m)^\s*(?:export\s+)?(?:const|let|var)\s+\w+\s*=.*(?:=>|;\s*$)|\bfunction\s+\w*\s*\(|\bconsole\.log\s*\("#) {
            return .javaScript
        }
        if matches(sample, #"(?m)^\s*(?:export\s+\w+=|(?:echo|printf|grep|sed|awk|cd)\s+|for\s+\w+\s+in\s+.*;\s*do\b)"#) {
            return .shell
        }
        if matches(sample, #"(?m)^\s*(?:#include\s*[<\"]|public\s+static\s+void\s+main\s*\(|SELECT\s+.+\s+FROM\s+)"#) {
            return .code
        }
        if looksLikeCSV(sample) { return .csv }
        return hasRichText ? .rich : .plain
    }

    private static func jsonClassification(text: String, sample: String, sampleLimit: Int) -> Self? {
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count >= 2,
           lines.prefix(2).allSatisfy({ line in
               let value = line.trimmingCharacters(in: .whitespaces)
               guard value.hasPrefix("{"), value.hasSuffix("}"),
                     let data = value.data(using: .utf8) else { return false }
               return (try? JSONSerialization.jsonObject(with: data)) != nil
           }) {
            return .jsonLines
        }
        guard sample.hasPrefix("{") || sample.hasPrefix("[") else { return nil }
        if text.dropFirst(sampleLimit).isEmpty {
            guard let data = text.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                return nil
            }
            return .json
        }
        // Long exports are classified from a complete opening key/value shape.
        // Their full bytes remain untouched and can be copied verbatim.
        if matches(sample, #"(?s)^\{\s*\"(?:\\.|[^\"\\])+\"\s*:"#) ||
            matches(sample, #"(?s)^\[\s*(?:\{\s*\"(?:\\.|[^\"\\])+\"\s*:|\"(?:\\.|[^\"\\])*\"|[-\d]|true|false|null|\[)"#) {
            return .json
        }
        return nil
    }

    private static func looksLikeCSV(_ sample: String) -> Bool {
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true).prefix(3)
        guard lines.count >= 3 else { return false }
        let counts = lines.map { line in
            line.reduce(into: 0) { count, character in if character == "," { count += 1 } }
        }
        return counts[0] >= 2 && counts.allSatisfy { $0 == counts[0] }
    }

    private static let expressionCache = NSCache<NSString, NSRegularExpression>()

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        if let cached = expressionCache.object(forKey: pattern as NSString) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        expressionCache.setObject(compiled, forKey: pattern as NSString)
        return compiled
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let regex = expression(pattern) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func matchCount(_ value: String, _ pattern: String) -> Int {
        guard let regex = expression(pattern) else { return 0 }
        return regex.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value))
    }
}

private final class CachedTextClassification: NSObject {
    let value: ClipboardTextClassification
    init(_ value: ClipboardTextClassification) { self.value = value }
}

extension ClipboardEntry {
    var textClassification: ClipboardTextClassification {
        let key = "\(id.uuidString)|\(sourceAppBundleID ?? "")|\(sourceAppName ?? "")|\(hasRichText)|\(text == nil)" as NSString
        if let cached = Self.classificationCache.object(forKey: key) { return cached.value }
        let value = ClipboardTextClassification.detect(
            text: text ?? "", hasRichText: hasRichText,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName
        )
        Self.classificationCache.setObject(CachedTextClassification(value), forKey: key)
        return value
    }

    private static let classificationCache: NSCache<NSString, CachedTextClassification> = {
        let cache = NSCache<NSString, CachedTextClassification>()
        cache.countLimit = 4_096
        return cache
    }()
}
