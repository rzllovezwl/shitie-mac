import SwiftUI

struct ClipboardContentToolsView: View {
    let sourceText: String
    let classification: ClipboardTextClassification
    let hasRichText: Bool
    let onCopy: (String) -> Bool

    @State private var operation: TextToolOperation
    @State private var output = TextToolOutput()
    @State private var isWorking = true
    @State private var didCopy = false

    init(sourceText: String, classification: ClipboardTextClassification,
         hasRichText: Bool, onCopy: @escaping (String) -> Bool) {
        self.sourceText = sourceText
        self.classification = classification
        self.hasRichText = hasRichText
        self.onCopy = onCopy
        _operation = State(initialValue: TextToolOperation.suggested(
            for: sourceText, classification: classification
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文本工具")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Menu {
                    Section("文本清理") {
                        operationButtons(in: "文本清理")
                    }
                    Section("开发辅助") {
                        operationButtons(in: "开发辅助")
                    }
                } label: {
                    Text(operation.title)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("选择文本处理方式：\(operation.title)")
            }

            if operation == .plainText {
                Text(hasRichText
                     ? "移除字体、颜色等富文本样式；复制结果只包含文字。"
                     : "这条记录已经是纯文本；复制结果仍只包含文字。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if operation == .removeSpaces {
                Text("删除普通空格、全角空格和制表符，保留换行。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if operation == .urlEncode || operation == .urlDecode {
                Text("按百分号编码处理；“+”保持原样。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            previewBlock(title: "原文", text: sourceText, maximumCharacters: 1_500)

            if isWorking {
                ProgressView("正在处理…")
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else if let error = output.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            } else {
                if let color = output.color {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("颜色预览")
                            .font(.system(size: 12, weight: .medium))
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(red: color.red, green: color.green,
                                        blue: color.blue, opacity: color.alpha))
                            .frame(height: 68)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.primary.opacity(0.15))
                            }
                        Text(color.rgba)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                previewBlock(title: operation == .colorPreview ? "标准 HEX" : "处理结果",
                             text: output.text ?? "", maximumCharacters: 5_000)
                if output.text == sourceText {
                    Text("结果与原文相同；原卡片仍保持不变。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("只复制结果，不修改原卡片")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(didCopy ? "已复制" : operation == .colorPreview ? "复制 HEX" : "复制结果") {
                    guard let result = output.text else { return }
                    didCopy = onCopy(result)
                }
                .disabled(isWorking || output.text?.isEmpty != false)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 480)
        .task(id: operation) {
            isWorking = true
            didCopy = false
            let source = sourceText
            let selectedOperation = operation
            let result = await Task.detached(priority: .userInitiated) {
                ClipboardContentTools.transform(source, operation: selectedOperation)
            }.value
            guard !Task.isCancelled else { return }
            output = result
            isWorking = false
        }
    }

    @ViewBuilder
    private func operationButtons(in category: String) -> some View {
        ForEach(TextToolOperation.allCases.filter { $0.category == category }) { item in
            Button(item.title) { operation = item }
        }
    }

    private func previewBlock(title: String, text: String,
                              maximumCharacters: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            ScrollView {
                Text(String(text.prefix(maximumCharacters)))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(maxHeight: 145)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8))
            if text.count > maximumCharacters {
                Text("这里只显示前 \(maximumCharacters) 字；复制会包含完整结果。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ClipboardLinkCleanerView: View {
    let cleaner: URLQueryCleaner
    let onCopy: (String) -> Bool

    @State private var selectedRemovalIDs: Set<Int>
    @State private var didCopy = false

    init(cleaner: URLQueryCleaner, onCopy: @escaping (String) -> Bool) {
        self.cleaner = cleaner
        self.onCopy = onCopy
        _selectedRemovalIDs = State(initialValue: cleaner.suggestedRemovalIDs)
    }

    private var result: String { cleaner.cleanedURL(removing: selectedRemovalIDs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("清理链接")
                .font(.system(size: 15, weight: .semibold))
            Text("只预选常见跟踪参数。逐项核对后再复制，原卡片不会改变。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if cleaner.parameters.isEmpty {
                Text("这条链接没有可选择的查询参数。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("勾选要删除的参数")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("只选常见跟踪项") {
                        selectedRemovalIDs = cleaner.suggestedRemovalIDs
                        didCopy = false
                    }
                    Button("全不选") {
                        selectedRemovalIDs.removeAll()
                        didCopy = false
                    }
                }
                .buttonStyle(.link)
                .controlSize(.small)
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(cleaner.parameters) { parameter in
                            Toggle(isOn: Binding(
                                get: { selectedRemovalIDs.contains(parameter.id) },
                                set: { remove in
                                    if remove { selectedRemovalIDs.insert(parameter.id) }
                                    else { selectedRemovalIDs.remove(parameter.id) }
                                    didCopy = false
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(parameter.name.isEmpty ? "（空名称）" : parameter.name)
                                            .font(.system(size: 12, weight: .medium,
                                                          design: .monospaced))
                                        if parameter.suggestedForRemoval {
                                            Text("常见跟踪项")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if let value = parameter.value {
                                        Text(value.isEmpty ? "（空值）" : value)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                }
                .frame(maxHeight: 230)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8))
            }

            Text("清理结果")
                .font(.system(size: 12, weight: .medium))
            ScrollView {
                Text(result)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(maxHeight: 135)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(selectedRemovalIDs.isEmpty
                     ? "没有选择删除项，结果与原链接相同。"
                     : "将删除 \(selectedRemovalIDs.count) 个参数。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(didCopy ? "已复制" : "复制清理后链接") {
                    didCopy = onCopy(result)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 500)
    }
}
