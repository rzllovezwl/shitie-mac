import Foundation

private enum ClassificationTestError: Error { case failed(String) }

@main
struct ClipboardTextClassificationSmoke {
    private static var failures: [String] = []

    static func main() throws {
        guard CardPreviewPreference.defaultEnabled else {
            throw ClassificationTestError.failed("格式预览应默认开启")
        }
        try check("# 版本说明\n\n- 第一项", rich: false, is: .markdown)
        try check("- 第一项\n- 第二项", rich: false, is: .markdown)
        try check("```swift\nlet value = 1\n```", rich: false, is: .markdown)
        try check("import SwiftUI\nstruct ClipView: View { var body: some View { Text(\"Hi\") } }",
                  rich: true, is: .swift)
        try check("import Foundation\nlet title = \"ClipHoook\"", rich: false, is: .swift)
        try check("{\"name\":\"ClipHoook\",\"enabled\":true}", rich: false, is: .json)
        try check("{\n  \"items\": [\n    {\"id\": 1},\n    {\"id\": 2}\n  ]\n}" + String(repeating: " ", count: 9_000),
                  rich: false, is: .json)
        try check("{\"id\":1}\n{\"id\":2}\n", rich: false, is: .jsonLines)
        try check("---\nname: ClipHoook\nenabled: true\n", rich: false, is: .yaml)
        try check("<?xml version=\"1.0\"?><items><item /></items>", rich: false, is: .xml)
        try check("<head><title>ClipHoook</title></head>", rich: false, is: .html)
        try check("<!DOCTYPE HTML><html><body>Text</body></html>", rich: false, is: .html)
        try check(".card {\n  color: red;\n  display: flex;\n}", rich: false, is: .css)
        try check("SELECT name FROM history WHERE id = 1;", rich: false, is: .sql)
        try check("name,kind,age\nclip,text,2\nimage,png,1\n", rich: false, is: .csv)
        try check("interface HistoryEntry {\n  title: string\n}", rich: false, is: .typeScript)
        try check("{\"name\":", rich: false, is: .plain)
        try check("def copy_text(value):\n    return value", rich: false, is: .python)
        try check("const count = items.map(x => x + 1);", rich: false, is: .javaScript)
        try check("#!/bin/zsh\necho ready", rich: false, is: .shell)
        // Each supported language gets a representative copied snippet. The
        // rich variants model browsers and editors that also add HTML/RTF.
        try check("#import <Foundation/Foundation.h>\n@interface Person : NSObject\n@end",
                  rich: true, is: .objectiveC)
        try check("package com.example;\npublic class Hello { public static void main(String[] args) {} }",
                  rich: false, is: .java)
        try check("fun main() {\n    println(\"Hello\")\n}", rich: true, is: .kotlin)
        try check("fun double(value: Int): Int = value * 2", rich: false, is: .kotlin)
        try check("package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"Hello\") }",
                  rich: false, is: .go)
        try check("fn main() {\n    let mut count = 0;\n    println!(\"{}\", count);\n}",
                  rich: true, is: .rust)
        try check("pub fn add(a: i32, b: i32) -> i32 { a + b }", rich: false, is: .rust)
        try check("use std::io;\nfn main() { println!(\"ready\"); }", rich: false, is: .rust)
        try check("#include <stdio.h>\nint main(void) { printf(\"Hello\"); return 0; }",
                  rich: false, is: .c)
        try check("#include <iostream>\nint main() { std::cout << \"Hello\"; }",
                  rich: false, is: .cpp)
        try check("#include <bits/stdc++.h>\nusing namespace std;", rich: false, is: .cpp)
        try check("using System;\nnamespace Demo { public class Hello {} }",
                  rich: true, is: .cSharp)
        try check("Console.WriteLine(\"Hello\");", rich: false, is: .cSharp)
        try check("<?php\necho 'Hello';\n?>", rich: false, is: .php)
        try check("def greet(name)\n  puts \"Hello, #{name}\"\nend", rich: false, is: .ruby)
        try check("import 'package:flutter/material.dart';\nvoid main() { runApp(const MyApp()); }",
                  rich: true, is: .dart)
        try check("- (void)viewDidLoad { [super viewDidLoad]; }",
                  rich: false, is: .objectiveC)
        try check("export default function App() { return <main>Hello</main>; }",
                  rich: false, is: .javaScript)
        try check("const App: React.FC<Props> = ({ name }) => <div>{name}</div>;",
                  rich: false, is: .typeScript)
        try check(".button { color: red; display: flex; }", rich: false, is: .css)
        try check("SELECT name, age\nFROM people\nWHERE age > 18;", rich: false, is: .sql)
        try check("<main><h1>Hello</h1></main>", rich: false, is: .html)
        try check("// a fragment without a unique language signature\nreturn count + 1;",
                  rich: false, is: .plain)
        try check("这是从文档里复制的一段说明，保留字体和颜色。", rich: true, is: .rich)
        try check("这是普通文字。", rich: false, is: .plain)
        try check("- 一条普通的文档列表", rich: true, is: .rich)
        try check("let value = 1", rich: false, source: "com.apple.dt.Xcode", is: .swift)
        let numberedDocument = "1. 数据统计与展示\n\n系统需支持按科室维度进行数据统计。"
        try check(numberedDocument, rich: true, name: "MWeb Pro", is: .markdown)
        try check(numberedDocument, rich: true, name: "Microsoft Word", is: .rich)
        try check("关于 Go、Rust 和 C++ 的技术选型说明。", rich: true, is: .rich)
        guard failures.isEmpty else {
            throw ClassificationTestError.failed(failures.joined(separator: "\n"))
        }
        print("ClipboardTextClassificationSmoke passed")
    }

    private static func check(
        _ value: String, rich: Bool, source: String? = nil, name: String? = nil,
        is expected: ClipboardTextClassification
    ) throws {
        let actual = ClipboardTextClassification.detect(
            text: value, hasRichText: rich, sourceAppBundleID: source,
            sourceAppName: name
        )
        if actual != expected {
            failures.append("\(value.prefix(35)): got \(actual.label), expected \(expected.label)")
        }
    }
}
