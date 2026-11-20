import AppKit
import SwiftUI

struct QuickSearchView: View {
    @ObservedObject var controller: QuickSearchController
    @ObservedObject var model: AppController

    private var searchesImages: Bool {
        !ClipboardQuickSearch.terms(in: controller.query).isEmpty && model.isSearchingImageText
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                LucideIcon(.search, size: 25).foregroundStyle(.secondary)
                QuickSearchField(text: $controller.query, onAttach: controller.attach)
                    .frame(maxWidth: .infinity, minHeight: 36)
                if controller.isMatching || searchesImages {
                    ProgressView().controlSize(.small)
                        .help(searchesImages ? "正在搜索图片中的文字" : "正在搜索剪贴板历史")
                } else if !controller.query.isEmpty {
                    Button {
                        controller.query = ""
                        controller.focusSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).help("清空搜索").accessibilityLabel("清空搜索")
                }
            }
            .padding(.horizontal, 22).frame(height: 68)
            Divider().opacity(0.45)
            if controller.results.isEmpty {
                VStack(spacing: 9) {
                    if controller.isMatching || searchesImages {
                        ProgressView().controlSize(.small)
                        Text(searchesImages ? "正在搜索图片文字…" : "正在搜索…")
                    } else {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                        Text(controller.query.isEmpty ? "复制的内容会出现在这里" : "未找到匹配的历史记录")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(controller.results) { result in
                                QuickSearchRow(result: result, query: controller.query,
                                    isSelected: controller.selectedID == result.id, controller: controller)
                                    .id(result.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: controller.selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            HStack(spacing: 8) {
                if let message = controller.message {
                    Text(message).foregroundStyle(.orange).lineLimit(1)
                } else if searchesImages {
                    Text("识别图片文字中…").foregroundStyle(.secondary)
                } else {
                    Text(controller.query.isEmpty ? "最近 \(controller.results.count) 条" : "\(controller.results.count) 条结果")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("↑↓ 选择   ↩ 粘贴   ⌘↩ 预览   Esc 关闭")
                    .foregroundStyle(.secondary).fixedSize()
            }
            .font(.caption2).padding(.horizontal, 20).frame(height: 29)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("剪贴板快速搜索")
    }
}

private struct QuickSearchRow: View {
    let result: ClipboardQuickSearchResult
    let query: String
    let isSelected: Bool
    let controller: QuickSearchController
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else {
                    Image(systemName: symbol).font(.system(size: 21, weight: .regular))
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(.primary.opacity(isSelected ? 0 : 0.035), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(highlightedSummary).font(.system(size: 14)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(result.source.isEmpty ? kindLabel : result.source)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
            }
            if result.entry.isFavorite {
                Image(systemName: "star.fill").font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .accessibilityLabel("已收藏")
            }
            if result.entry.shelfPinOrder != nil {
                Image(systemName: "pin.fill").font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .accessibilityLabel("已钉住")
            }
            Text(result.entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10)).foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                .lineLimit(1).fixedSize()
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 12).frame(height: 54)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture(count: 2) { controller.select(result.id); controller.pasteSelected() }
        .onTapGesture { controller.select(result.id) }
        .contextMenu {
            Button("预览   ⌘↩") { controller.select(result.id); controller.togglePreview() }
            Button("复制") { controller.select(result.id); controller.copySelected() }
            Button("按设置粘贴   ↩") { controller.select(result.id); controller.pasteSelected() }
        }
        .padding(.horizontal, 8)
        .task(id: "\(result.id)-\(result.entry.digest)") {
            thumbnail = await controller.thumbnail(for: result.entry)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { controller.select(result.id); controller.togglePreview() }
    }

    private var symbol: String {
        switch result.entry.kind {
        case .text: "doc.text"
        case .link: "link"
        case .image, .unavailableImage: "photo"
        case .fileReference: "doc"
        case .group: "square.stack"
        }
    }

    private var kindLabel: String {
        switch result.entry.kind {
        case .text: "文字"
        case .link: "链接"
        case .image, .unavailableImage: "图片"
        case .fileReference: "文件"
        case .group: "分组"
        }
    }

    private var highlightedSummary: AttributedString {
        var value = AttributedString(result.summary)
        for word in ClipboardQuickSearch.terms(in: query) {
            var start = result.summary.startIndex
            while start < result.summary.endIndex,
                  let range = result.summary.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                                   range: start..<result.summary.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: value),
                   let upper = AttributedString.Index(range.upperBound, within: value) {
                    value[lower..<upper].foregroundColor = isSelected ? .white : .accentColor
                    value[lower..<upper].font = .system(size: 14, weight: .semibold)
                }
                start = range.upperBound
            }
        }
        return value
    }
}

private struct QuickSearchField: NSViewRepresentable {
    @Binding var text: String
    let onAttach: (NSSearchField) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索剪贴板历史"
        field.font = .systemFont(ofSize: 23)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.setAccessibilityLabel("搜索剪贴板历史")
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        onAttach(field)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: QuickSearchField
        init(_ parent: QuickSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
    }
}
