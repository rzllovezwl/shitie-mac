import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import os

enum ClipboardTimeLabel {
    private static let timeFormatter = formatter("HH:mm")
    private static let monthDayFormatter = formatter("M/d")
    private static let fullDateFormatter = formatter("yyyy/M/d")

    static func compact(_ date: Date, now: Date = Date()) -> String {
        let time = timeFormatter.string(from: date)
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(monthDayFormatter.string(from: date)) \(time)"
        }
        return "\(fullDateFormatter.string(from: date)) \(time)"
    }

    static func detail(_ date: Date, now: Date = Date()) -> String {
        let label = compact(date, now: now)
        return Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now) ? "今天 \(label)" : label
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = pattern
        return formatter
    }
}

private extension ClipboardEntry {
    var contentTypeLabel: String {
        if isScreenRecording { return "录屏" }
        if kind == .fileReference {
            let fileExtension = URL(fileURLWithPath: fileName ?? "").pathExtension
            let type = fileType.flatMap(UTType.init) ?? UTType(filenameExtension: fileExtension)
            return type?.localizedDescription ?? "文件"
        }
        return switch kind {
        case .group: "分组"
        case .image: "图片"
        case .unavailableImage: "图片未保存"
        case .fileReference: "文件"
        case .link: "链接"
        case .text: textClassification.label
        }
    }
}

private final class CachedCardPreview: NSObject {
    let result: TextPreviewResult
    init(_ result: TextPreviewResult) { self.result = result }
}

private enum CardPreviewCache {
    static let results: NSCache<NSString, CachedCardPreview> = {
        let cache = NSCache<NSString, CachedCardPreview>()
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
}

struct ClipboardGroupMembership {
    let position: Int
    let count: Int
}

struct CardContextAction {
    let title: String
    let shortcut: String?
    let isEnabled: Bool
    let perform: () -> Void
    let children: [CardContextAction]

    init(_ title: String, shortcut: String? = nil, isEnabled: Bool = true,
         perform: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.perform = perform
        children = []
    }

    init(_ title: String, shortcut: String? = nil, children: [CardContextAction]) {
        self.title = title
        self.shortcut = shortcut
        isEnabled = true
        perform = {}
        self.children = children
    }
}

private struct FavoriteStarAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct FavoriteStarButton: View {
    let shortcut: String
    let action: () -> Void
    var scale: CGFloat = 1
    var body: some View {
        Button(action: action) {
            LucideIcon(.star, size: 14 * scale)
                .frame(width: 24 * scale, height: 24 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.yellow)
        .help("取消收藏（\(shortcut)）")
        .accessibilityLabel("取消收藏")
    }
}

private struct ShelfPinAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct ShelfUnpinButton: View {
    let scale: CGFloat
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon(.pin, size: 13 * scale)
                .frame(width: 20 * scale, height: 24 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help("取消面板钉住（\(shortcut)）")
        .accessibilityLabel("取消面板钉住")
    }
}

private extension View {
    func shelfPinOverlay(shortcut: String, action: (() -> Void)?, scale: CGFloat) -> some View {
        overlayPreferenceValue(ShelfPinAnchorKey.self) { anchor in
            if let anchor, let action {
                GeometryReader { geometry in
                    let frame = geometry[anchor]
                    ShelfUnpinButton(scale: scale, shortcut: shortcut, action: action)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }

    func favoriteStarOverlay(shortcut: String, action: (() -> Void)?, scale: CGFloat) -> some View {
        overlayPreferenceValue(FavoriteStarAnchorKey.self) { anchor in
            if let anchor, let action {
                GeometryReader { geometry in
                    let frame = geometry[anchor]
                    FavoriteStarButton(shortcut: shortcut, action: action, scale: scale)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }
}

struct ClipboardCardView: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let thumbnailURL: URL?
    let fileHasSavedCopy: Bool
    let richTextFiles: RichTextSourceFiles
    let formattedPreviewEnabled: Bool
    let cardSize: CGSize
    let isSelected: Bool
    let groupMembership: ClipboardGroupMembership?
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let canRecognizeImage: Bool
    let recognizeShortcut: String
    let onRecognizeImage: () -> Void
    var onContextSelect: (() -> Void)? = nil
    var makeContextMenu: (() -> [[CardContextAction]])? = nil
    let onOpenSource: () -> Void
    let onBeginDrag: () -> ClipboardDragPayload?
    let onDragStarted: () -> Void
    var onDragMoved: ((NSPoint) -> Void)? = nil
    let onEndDrag: (Bool) -> Void
    var onCancelFavorite: (() -> Void)? = nil
    var favoriteShortcut = AppShortcutAction.toggleFavorite.defaultShortcut.displayName
    var onCancelShelfPin: (() -> Void)? = nil
    var shelfPinShortcut = AppShortcutAction.toggleShelfPin.defaultShortcut.displayName
    @State private var previewResult: TextPreviewResult?

    private var previewMode: TextPreviewMode {
        TextPreviewMode.suggested(for: entry.textClassification, hasRichText: entry.hasRichText)
    }

    private var previewKey: String {
        "\(entry.id.uuidString)-\(entry.digest)-\(formattedPreviewEnabled)-\(previewMode.rawValue)"
    }

    private var accessibilityDescription: String {
        let groupPrefix: String
        if let groupMembership {
            groupPrefix = "组内第\(groupMembership.position)项，共\(groupMembership.count)项，"
        } else {
            groupPrefix = ""
        }
        let pinPrefix = entry.shelfPinOrder == nil ? "" : "已钉在面板，"
        return pinPrefix + (entry.isFavorite ? "已收藏，" : "") + groupPrefix + entry.title + "，单击选中，空格查看或收起详情，方向键切换，双击粘贴，按住拖到其他应用，拖动时按 Esc 取消"
    }

    private var textScale: CGFloat {
        min(1.25, max(0.9, cardSize.height / 252))
    }

    private var recognizeButtonBottomInset: CGFloat {
        entry.kind == .fileReference
            ? min(cardSize.height * 0.3, 76 * textScale)
            : 48 * textScale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * textScale) {
            HStack(spacing: 6) {
                ClipboardContentTypeIcon(entry: entry, size: 15 * textScale)
                Text(entry.contentTypeLabel)
                    .lineLimit(1)
                    .layoutPriority(-1)
                    .help(entry.kind == .text ? "根据内容推测的文本类型" : entry.contentTypeLabel)
                Spacer(minLength: 4)
                if let groupMembership {
                    Text("\(groupMembership.position)/\(groupMembership.count)")
                        .font(.system(size: 9 * textScale, weight: .semibold))
                        .padding(.horizontal, 5 * textScale)
                        .padding(.vertical, 2 * textScale)
                        .background(.primary.opacity(0.09), in: Capsule())
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                if entry.shelfPinOrder != nil {
                    Color.clear.frame(width: 20 * textScale, height: 15 * textScale)
                        .anchorPreference(key: ShelfPinAnchorKey.self, value: .bounds) { $0 }
                        .accessibilityHidden(true)
                }
                if entry.isFavorite {
                    Color.clear.frame(width: 14 * textScale, height: 15 * textScale)
                        .anchorPreference(key: FavoriteStarAnchorKey.self, value: .bounds) { $0 }
                        .accessibilityHidden(true)
                }
                Text(ClipboardTimeLabel.compact(entry.createdAt))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(entry.createdAt.formatted(date: .complete, time: .standard))
            }
            .font(.system(size: 11 * textScale, weight: .medium))
            .foregroundStyle(.secondary)

            Group {
                if entry.kind == .group {
                    EmptyView()
                } else if entry.kind == .image, let imageURL {
                    ClipboardImageThumbnailView(url: imageURL)
                } else if entry.kind == .image {
                    Text("图片文件不可用")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entry.kind == .unavailableImage {
                    VStack(spacing: 9 * textScale) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 27 * textScale))
                        Text("微信图片未保存")
                            .font(.system(size: 13 * textScale, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entry.kind == .fileReference {
                    FileReferencePreview(entry: entry, thumbnailURL: thumbnailURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entry.kind == .link {
                    VStack(alignment: .leading, spacing: 9 * textScale) {
                        if let host = entry.webURL?.host {
                            Text(host)
                                .font(.system(size: 15 * textScale, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        Text(String((entry.text ?? "链接不可用")
                            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200)))
                            .font(.system(size: 12 * textScale))
                            .foregroundStyle(Color.accentColor)
                            .underline()
                            .lineLimit(7)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if formattedPreviewEnabled, let previewResult {
                    TextPreviewView(content: previewResult.text, interactive: false)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(previewMode == .original && previewResult.actualRichText
                                    ? Color.white : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Text(String((entry.text ?? "内容文件不可用").prefix(1_200)))
                        .font(.system(size: 14 * textScale))
                        .foregroundStyle(.primary)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 5) {
                SourceAppIconView(
                    bundleID: entry.sourceAppBundleID,
                    name: entry.sourceAppName,
                    size: 18 * textScale
                )
                Text(entry.sourceAppName ?? "未知来源")
                    .lineLimit(1)
                if entry.kind == .fileReference && fileHasSavedCopy {
                    SavedFileCopyBadge(fontSize: 9 * textScale)
                }
                Spacer()
                if entry.sourceAppBundleID != nil || entry.sourceAppName != nil {
                    Color.clear.frame(width: 18 * textScale, height: 18 * textScale)
                }
            }
            .font(.system(size: 10 * textScale))
            .foregroundStyle(.tertiary)
        }
        .padding(14 * textScale)
        .frame(width: cardSize.width, height: cardSize.height)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .overlay {
            ImmediateCardInteraction(
                onSelect: onSelect,
                onPaste: onPaste,
                onCopy: onCopy,
                onDelete: onDelete,
                onContextSelect: onContextSelect,
                makeContextMenu: makeContextMenu,
                onBeginDrag: onBeginDrag,
                onDragStarted: onDragStarted,
                onDragMoved: onDragMoved,
                onEndDrag: onEndDrag,
                dragPreviewURL: entry.kind == .image ? imageURL : thumbnailURL,
                dragSymbolName: entry.kind == .link ? "link" : "doc.on.clipboard",
                deferSelectionUntilMouseUp: true
            )
        }
        .favoriteStarOverlay(shortcut: favoriteShortcut, action: onCancelFavorite, scale: textScale)
        .shelfPinOverlay(shortcut: shelfPinShortcut, action: onCancelShelfPin, scale: textScale)
        .overlay(alignment: .bottomTrailing) {
            if canRecognizeImage {
                Button(action: onRecognizeImage) {
                    LucideIcon(.scanSearch, size: 15 * textScale)
                        .frame(width: 30 * textScale, height: 30 * textScale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8 * textScale))
                .overlay {
                    RoundedRectangle(cornerRadius: 8 * textScale)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                .help("识别图片文字（\(recognizeShortcut)）")
                .accessibilityLabel("识别图片文字")
                .accessibilityHint("打开预览并开始识别，快捷键 \(recognizeShortcut)")
                .padding(.trailing, 12 * textScale)
                .padding(.bottom, recognizeButtonBottomInset)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if entry.sourceAppBundleID != nil || entry.sourceAppName != nil {
                Button(action: onOpenSource) {
                    LucideIcon(.arrowUpLeft, size: 11 * textScale)
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: 28 * textScale, height: 28 * textScale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("打开来源应用：\(entry.sourceAppName ?? entry.sourceAppBundleID ?? "未知")")
                .accessibilityLabel("打开来源应用：\(entry.sourceAppName ?? entry.sourceAppBundleID ?? "未知")")
                .padding(.trailing, 4 * textScale)
                .padding(.bottom, 9 * textScale)
            }
        }
        .task(id: previewKey) {
            previewResult = nil
            guard formattedPreviewEnabled,
                  entry.kind == .text,
                  previewMode != .plain else { return }
            let cacheKey = previewKey as NSString
            if let cached = CardPreviewCache.results.object(forKey: cacheKey) {
                previewResult = cached.result
                return
            }
            let result = await TextPreviewRenderer.render(
                mode: previewMode,
                raw: entry.text ?? "内容文件不可用",
                files: richTextFiles,
                language: entry.textClassification.codeLanguage ?? "自动",
                maximumCharacters: 1_200
            )
            guard !Task.isCancelled else { return }
            CardPreviewCache.results.setObject(
                CachedCardPreview(result), forKey: cacheKey,
                cost: max(1, result.text.length * 16)
            )
            previewResult = result
        }
    }
}

struct ClipboardGroupCardView: View {
    let entry: ClipboardEntry
    let cardSize: CGSize
    let isSelected: Bool
    let isExpanded: Bool
    let canExpand: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    var onContextSelect: (() -> Void)? = nil
    var makeContextMenu: (() -> [[CardContextAction]])? = nil
    let onBeginDrag: () -> ClipboardDragPayload?
    let onDragStarted: () -> Void
    var onDragMoved: ((NSPoint) -> Void)? = nil
    let onEndDrag: (Bool) -> Void
    var onCancelFavorite: (() -> Void)? = nil
    var favoriteShortcut = AppShortcutAction.toggleFavorite.defaultShortcut.displayName
    var onCancelShelfPin: (() -> Void)? = nil
    var shelfPinShortcut = AppShortcutAction.toggleShelfPin.defaultShortcut.displayName

    private var textScale: CGFloat { min(1.25, max(0.9, cardSize.height / 252)) }

    private var expansionLabel: String {
        canExpand ? (isExpanded ? "收起" : "展开") : "成员已在钉住区"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * textScale) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 13 * textScale, weight: .semibold))
                Text("\(entry.groupMemberIDs.count) 项分组")
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .layoutPriority(-1)
                if entry.containsUnavailableImage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("组内有图片未保存，不能完整复制")
                }
                if let count = entry.copyCount, count > 1 {
                    Text("×\(count)")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 3)
                if entry.shelfPinOrder != nil {
                    Color.clear.frame(width: 20 * textScale, height: 15 * textScale)
                        .anchorPreference(key: ShelfPinAnchorKey.self, value: .bounds) { $0 }
                        .accessibilityHidden(true)
                }
                if entry.isFavorite {
                    Color.clear.frame(width: 14 * textScale, height: 15 * textScale)
                        .anchorPreference(key: FavoriteStarAnchorKey.self, value: .bounds) { $0 }
                        .accessibilityHidden(true)
                }
                Text(ClipboardTimeLabel.compact(entry.createdAt))
                    .lineLimit(1)
            }
            .font(.system(size: 11 * textScale))
            .foregroundStyle(.secondary)

            Group {
                if isExpanded {
                    VStack(spacing: 8 * textScale) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 28 * textScale, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("\(entry.groupMembers.count) 项内容")
                            .font(.system(size: 17 * textScale, weight: .semibold))
                        Text("已展开，可逐项查看和操作")
                            .font(.system(size: 10 * textScale))
                            .foregroundStyle(.secondary)
                        if entry.containsUnavailableImage {
                            Text("部分图片未保存")
                                .font(.system(size: 10 * textScale))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 7 * textScale) {
                        ForEach(Array(entry.groupMembers.prefix(4).enumerated()), id: \.offset) { _, member in
                            HStack(spacing: 7) {
                                ClipboardContentTypeIcon(entry: member, size: 13 * textScale)
                                    .foregroundStyle(.secondary)
                                Text(member.title)
                                    .font(.system(size: 12 * textScale))
                                    .lineLimit(1)
                            }
                        }
                        if entry.groupMembers.count > 4 {
                            Text("还有 \(entry.groupMembers.count - 4) 项")
                                .font(.system(size: 10 * textScale))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            HStack(spacing: 5) {
                SourceAppIconView(
                    bundleID: entry.sourceAppBundleID,
                    name: entry.sourceAppName,
                    size: 18 * textScale
                )
                Text(entry.sourceAppName ?? "未知来源")
                    .lineLimit(1)
                Spacer(minLength: 3)
                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11 * textScale, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Text(expansionLabel)
                    .lineLimit(1)
            }
            .font(.system(size: 10 * textScale))
            .foregroundStyle(.secondary)
        }
        .padding(14 * textScale)
        .frame(width: cardSize.width, height: cardSize.height)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 2 : 1)
        }
        .overlay {
            ImmediateCardInteraction(
                onSelect: onSelect, onPaste: onPaste,
                onCopy: onCopy, onDelete: onDelete,
                onContextSelect: onContextSelect,
                makeContextMenu: makeContextMenu,
                onBeginDrag: onBeginDrag, onDragStarted: onDragStarted,
                onDragMoved: onDragMoved,
                onEndDrag: onEndDrag,
                dragSymbolName: "square.stack.3d.up",
                deferSelectionUntilMouseUp: true
            )
        }
        .favoriteStarOverlay(shortcut: favoriteShortcut, action: onCancelFavorite, scale: textScale)
        .shelfPinOverlay(shortcut: shelfPinShortcut, action: onCancelShelfPin, scale: textScale)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.shelfPinOrder == nil ? "" : "已钉在面板，")\(entry.groupMemberIDs.count) 项分组，\(canExpand ? "单击" : "")\(expansionLabel)，双击粘贴，按住拖到其他应用")
    }
}

struct ClipboardListRowView: View {
    let entry: ClipboardEntry
    let thumbnailURL: URL?
    let isSelected: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    private var kindName: String {
        entry.contentTypeLabel
    }

    private var summary: String {
        switch entry.kind {
        case .group: "分组，点击展开"
        case .image: "图片记录，按空格查看预览"
        case .unavailableImage: "微信未提供可读取的图片内容"
        case .fileReference: entry.fileType ?? "仅保存原文件位置"
        case .text, .link:
            // This is a display-only excerpt; the saved text stays byte-for-byte intact.
            String((entry.text ?? "内容文件不可用").prefix(180))
                .replacingOccurrences(of: "\n", with: " ↵ ")
                .replacingOccurrences(of: "\t", with: " ⇥ ")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.primary.opacity(0.06))
                if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    ClipboardContentTypeIcon(entry: entry, size: 23)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(kindName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if entry.isFavorite {
                        LucideIcon(.star, size: 12)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("已收藏")
                    }
                    Text(ClipboardTimeLabel.compact(entry.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(entry.createdAt.formatted(date: .complete, time: .standard))
                }
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    SourceAppIconView(bundleID: entry.sourceAppBundleID, name: entry.sourceAppName, size: 16)
                    Text(entry.sourceAppName ?? "未知来源")
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
        .overlay {
            ImmediateCardInteraction(
                onSelect: onSelect,
                onPaste: onPaste,
                onCopy: onCopy,
                onDelete: onDelete
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindName)：\(entry.title)，来自\(entry.sourceAppName ?? "未知来源")，双击粘贴")
    }
}

struct ImmediateCardInteraction: NSViewRepresentable {
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    var onContextSelect: (() -> Void)? = nil
    var makeContextMenu: (() -> [[CardContextAction]])? = nil
    var onBeginDrag: (() -> ClipboardDragPayload?)? = nil
    var onDragStarted: (() -> Void)? = nil
    var onDragMoved: ((NSPoint) -> Void)? = nil
    var onEndDrag: ((Bool) -> Void)? = nil
    var dragPreviewURL: URL? = nil
    var dragSymbolName = "doc.on.clipboard"
    var deferSelectionUntilMouseUp = false

    func makeNSView(context: Context) -> CardInteractionView {
        CardInteractionView()
    }

    func updateNSView(_ view: CardInteractionView, context: Context) {
        view.onSelect = onSelect
        view.onPaste = onPaste
        view.onCopy = onCopy
        view.onDelete = onDelete
        view.onContextSelect = onContextSelect
        view.makeContextMenu = makeContextMenu
        view.onBeginDrag = onBeginDrag
        view.onDragStarted = onDragStarted
        view.onDragMoved = onDragMoved
        view.onEndDrag = onEndDrag
        view.dragPreviewURL = dragPreviewURL
        view.dragSymbolName = dragSymbolName
        view.deferSelectionUntilMouseUp = deferSelectionUntilMouseUp
    }
}

struct FavoriteDropViewport: NSViewRepresentable {
    func makeNSView(context: Context) -> FavoriteDropViewportView { FavoriteDropViewportView() }
    func updateNSView(_ view: FavoriteDropViewportView, context: Context) {}
}

struct FavoriteDropRegion: NSViewRepresentable {
    let label: String
    let help: String
    var isSelected = false
    var onOpen: (() -> Void)? = nil
    let onTargeted: (Bool) -> Void
    let onDrop: ([UUID]) -> Bool
    var clipsToFavoriteViewport = true
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    func makeNSView(context: Context) -> FavoriteDropView { FavoriteDropView(frame: .zero) }

    func updateNSView(_ view: FavoriteDropView, context: Context) {
        view.onOpen = onOpen
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.clipsToFavoriteViewport = clipsToFavoriteViewport
        view.onEdit = onEdit
        view.onDelete = onDelete
        view.toolTip = onOpen == nil ? nil : help
        view.setAccessibilityElement(onOpen != nil)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp(help)
        view.setAccessibilitySelected(isSelected)
    }
}

struct CardReorderDropRegion: NSViewRepresentable {
    let entryID: UUID
    let scope: ClipboardCardOrderScope
    let isVertical: Bool
    let onDrop: ([UUID], Bool) -> Bool

    func makeNSView(context: Context) -> CardReorderDropView { CardReorderDropView() }
    func updateNSView(_ view: CardReorderDropView, context: Context) {
        view.entryID = entryID
        view.scope = scope
        view.isVertical = isVertical
        view.onDrop = onDrop
    }
}

struct CardReorderViewport: NSViewRepresentable {
    func makeNSView(context: Context) -> CardReorderViewportView { CardReorderViewportView() }
    func updateNSView(_ view: CardReorderViewportView, context: Context) {}
}

final class CardReorderViewportView: NSView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { (window as? ShelfPanel)?.reorderViewports.remove(self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? ShelfPanel)?.reorderViewports.add(self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CardReorderDropView: NSView {
    var entryID = UUID()
    var scope: ClipboardCardOrderScope = .history
    var isVertical = false
    var onDrop: (([UUID], Bool) -> Bool)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { (window as? ShelfPanel)?.reorderDropViews.remove(self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? ShelfPanel)?.reorderDropViews.add(self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CardReorderIndicator: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 1.5
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ShelfPanel: ShelfKeyboardPanel {
    weak var localCardDragSource: CardInteractionView?
    var nativeCardDragSource: CardInteractionView?
    weak var favoriteDropViewport: FavoriteDropViewportView?
    private let favoriteDropViews = NSHashTable<FavoriteDropView>.weakObjects()
    private weak var targetedFavoriteDropView: FavoriteDropView?
    private var cardDragPreview: ShelfCardDragPreview?
    fileprivate let reorderDropViews = NSHashTable<CardReorderDropView>.weakObjects()
    fileprivate let reorderViewports = NSHashTable<CardReorderViewportView>.weakObjects()
    private var reorderIndicator: CardReorderIndicator?
    private var reorderScrollTimer: Timer?
    private var reorderDragPoint: NSPoint?
    private var reorderDragIDs: [UUID] = []
    private var reorderDragScope: ClipboardCardOrderScope?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func registerFavoriteDropView(_ view: FavoriteDropView) { favoriteDropViews.add(view) }

    func unregisterFavoriteDropView(_ view: FavoriteDropView) { favoriteDropViews.remove(view) }

    func isInsideFavoriteViewport(_ windowPoint: NSPoint) -> Bool {
        guard let viewport = favoriteDropViewport, viewport.window === self else { return true }
        return viewport.bounds.contains(viewport.convert(windowPoint, from: nil))
    }

    func favoriteDropTarget(at windowPoint: NSPoint) -> FavoriteDropView? {
        favoriteDropViews.allObjects.first { $0.contains(windowPoint: windowPoint) }
    }

    func showLocalCardDrag(_ artwork: NSImage, at windowPoint: NSPoint,
                          ids: [UUID] = [], scope: ClipboardCardOrderScope? = nil) {
        guard let contentView else { return }
        let preview: ShelfCardDragPreview
        if let cardDragPreview {
            preview = cardDragPreview
        } else {
            preview = ShelfCardDragPreview(artwork: artwork)
            contentView.addSubview(preview, positioned: .above, relativeTo: nil)
            cardDragPreview = preview
        }
        let center = contentView.convert(windowPoint, from: nil)
        preview.setFrameOrigin(NSPoint(x: center.x - preview.bounds.width / 2,
                                       y: center.y - preview.bounds.height / 2))
        let target = favoriteDropTarget(at: windowPoint)
        if targetedFavoriteDropView !== target {
            targetedFavoriteDropView?.setTargeted(false)
            targetedFavoriteDropView = target
            target?.setTargeted(true)
        }
        preview.showsDropBadge = target != nil
        reorderDragPoint = windowPoint
        reorderDragIDs = ids
        reorderDragScope = scope
        updateReorderIndicator()
        if scope != nil && reorderScrollTimer == nil {
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscrollReordering() }
            }
            RunLoop.main.add(timer, forMode: .common)
            reorderScrollTimer = timer
        }
    }

    // Resolve against the clipped lane, including gaps between cards. Pinned
    // cards and expanded group members only accept drags from their own scope.
    func cardReorderTarget(at point: NSPoint, ids: [UUID], scope: ClipboardCardOrderScope?)
        -> (view: CardReorderDropView, after: Bool, viewport: NSRect)? {
        guard let scope, !ids.isEmpty, favoriteDropTarget(at: point) == nil,
              let viewport = reorderViewports.allObjects.first(where: {
                  !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(point)
              }) else { return nil }
        let viewportRect = viewport.convert(viewport.bounds, to: nil)
        let chosen = Set(ids)
        let candidates = reorderDropViews.allObjects.filter {
            $0.scope == scope && !chosen.contains($0.entryID) && !$0.isHiddenOrHasHiddenAncestor &&
            !$0.convert($0.visibleRect, to: nil).intersection(viewportRect).isEmpty
        }
        let target = candidates.min { left, right in
            func distance(_ view: CardReorderDropView) -> CGFloat {
                let rect = view.convert(view.bounds, to: nil).intersection(viewportRect)
                return view.isVertical ? abs(point.y - rect.midY) : abs(point.x - rect.midX)
            }
            return distance(left) < distance(right)
        }
        guard let target else { return nil }
        let rect = target.convert(target.bounds, to: nil)
        return (target, target.isVertical ? point.y < rect.midY : point.x > rect.midX, viewportRect)
    }

    func localCardDropAction(at point: NSPoint, ids: [UUID], scope: ClipboardCardOrderScope?) -> (() -> Void)? {
        if let favorite = favoriteDropTarget(at: point), let drop = favorite.onDrop {
            return { _ = drop(ids) }
        }
        guard let target = cardReorderTarget(at: point, ids: ids, scope: scope),
              let drop = target.view.onDrop else { return nil }
        return { _ = drop(ids, target.after) }
    }

    private func updateReorderIndicator() {
        guard let contentView, let point = reorderDragPoint,
              let target = cardReorderTarget(at: point, ids: reorderDragIDs, scope: reorderDragScope) else {
            reorderIndicator?.isHidden = true
            return
        }
        let rect = target.view.convert(target.view.bounds, to: nil)
        let viewport = target.viewport
        let line: NSRect
        if target.view.isVertical {
            let y = target.after ? rect.minY - 3 : rect.maxY + 3
            line = NSRect(x: max(rect.minX, viewport.minX) + 4,
                          y: min(max(y, viewport.minY + 2), viewport.maxY - 2) - 1.5,
                          width: max(3, rect.intersection(viewport).width - 8), height: 3)
        } else {
            let x = target.after ? rect.maxX + 3 : rect.minX - 3
            line = NSRect(x: min(max(x, viewport.minX + 2), viewport.maxX - 2) - 1.5,
                          y: max(rect.minY, viewport.minY) + 4,
                          width: 3, height: max(3, rect.intersection(viewport).height - 8))
        }
        if reorderIndicator == nil {
            let indicator = CardReorderIndicator(frame: .zero)
            contentView.addSubview(indicator, positioned: .above, relativeTo: nil)
            reorderIndicator = indicator
        }
        reorderIndicator?.frame = contentView.convert(line, from: nil)
        reorderIndicator?.isHidden = false
    }

    private func autoscrollReordering() {
        guard let point = reorderDragPoint,
              let target = cardReorderTarget(at: point, ids: reorderDragIDs, scope: reorderDragScope),
              let scroll = target.view.enclosingScrollView,
              let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let old = clip.bounds.origin
        var origin = old
        let rect = target.viewport
        if target.view.isVertical {
            let direction: CGFloat = point.y < rect.minY + 28 ? -1 : (point.y > rect.maxY - 28 ? 1 : 0)
            origin.y += direction * (document.isFlipped ? -12 : 12)
        } else {
            origin.x += point.x < rect.minX + 28 ? -12 : (point.x > rect.maxX - 28 ? 12 : 0)
        }
        origin.x = min(max(origin.x, document.bounds.minX), max(document.bounds.minX, document.bounds.maxX - clip.bounds.width))
        origin.y = min(max(origin.y, document.bounds.minY), max(document.bounds.minY, document.bounds.maxY - clip.bounds.height))
        if origin != old {
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
            updateReorderIndicator()
        }
    }

    func clearLocalCardDragPreview() {
        cardDragPreview?.removeFromSuperview()
        cardDragPreview = nil
        targetedFavoriteDropView?.setTargeted(false)
        targetedFavoriteDropView = nil
        reorderIndicator?.removeFromSuperview()
        reorderIndicator = nil
        reorderScrollTimer?.invalidate()
        reorderScrollTimer = nil
        reorderDragPoint = nil
        reorderDragIDs = []
        reorderDragScope = nil
    }
}

private final class ShelfCardDragPreview: NSImageView {
    private let badge = NSImageView(frame: .zero)

    init(artwork: NSImage) {
        super.init(frame: NSRect(origin: .zero, size: artwork.size))
        image = artwork
        imageScaling = .scaleNone
        badge.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemGreen]))
        badge.frame = NSRect(x: bounds.width - 17, y: isFlipped ? bounds.height - 17 : 0,
                             width: 17, height: 17)
        badge.isHidden = true
        addSubview(badge)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var showsDropBadge: Bool {
        get { !badge.isHidden }
        set { badge.isHidden = !newValue }
    }
}

final class FavoriteDropViewportView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? ShelfPanel)?.favoriteDropViewport = self
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FavoriteDropView: NSView {
    var onOpen: (() -> Void)?
    var onTargeted: ((Bool) -> Void)?
    var onDrop: (([UUID]) -> Bool)?
    var clipsToFavoriteViewport = true
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    private var isTargeted = false
    private var pressed = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            (window as? ShelfPanel)?.unregisterFavoriteDropView(self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? ShelfPanel)?.registerFavoriteDropView(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onOpen != nil else { return nil }
        if let superview, !contains(windowPoint: superview.convert(point, to: nil)) { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if pressed && contains(windowPoint: event.locationInWindow) { onOpen?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onOpen else { return false }
        onOpen()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onEdit != nil, onDelete != nil else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "编辑分类…", action: #selector(editCategory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "删除分类…", action: #selector(deleteCategory), keyEquivalent: "").target = self
        return menu
    }

    @objc private func editCategory() { onEdit?() }
    @objc private func deleteCategory() { onDelete?() }

    func contains(windowPoint: NSPoint) -> Bool {
        window != nil && !isHiddenOrHasHiddenAncestor &&
            bounds.intersection(visibleRect).contains(convert(windowPoint, from: nil)) &&
            (!clipsToFavoriteViewport || (window as? ShelfPanel)?.isInsideFavoriteViewport(windowPoint) != false)
    }

    func setTargeted(_ active: Bool) {
        guard active != isTargeted else { return }
        isTargeted = active
        onTargeted?(active)
    }
}

// Keep press, local movement and the native handoff in one recognizer. Views
// must not also override mouseDown/Dragged/Up: that retains AppKit's legacy
// tracking path even when beginDraggingSession receives a gesture.
class ContentDragGestureRecognizer: NSGestureRecognizer {
    private(set) var initialEvent: NSEvent?
    private(set) var pointerEvent: NSEvent?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = []
        delaysPrimaryMouseButtonEvents = false
        delaysKeyEvents = false
    }
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        initialEvent = event
        pointerEvent = event
        state = .began
    }
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        guard state == .began || state == .changed else { return }
        pointerEvent = event
        state = .changed
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard state == .began || state == .changed else { return }
        pointerEvent = event
        state = .ended
    }
    override func mouseCancelled(with event: NSEvent) {
        if #available(macOS 26.0, *) { super.mouseCancelled(with: event) }
        pointerEvent = event
        if state == .began || state == .changed { state = .cancelled }
    }
    override func location(in view: NSView?) -> NSPoint {
        let point = pointerEvent?.locationInWindow ?? .zero
        return view?.convert(point, from: nil) ?? point
    }
    override func reset() {
        super.reset()
        initialEvent = nil
        pointerEvent = nil
    }
    var trackingDescription: String {
        "state=\(state.rawValue) enabled=\(isEnabled) event=\(pointerEvent?.type.rawValue ?? 0)"
    }
}

class CardInteractionView: NSView, NSDraggingSource, NSGestureRecognizerDelegate {
#if DEBUG
    private static let dragLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ClipHoook", category: "CardDrag"
    )
#endif
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onContextSelect: (() -> Void)?
    var makeContextMenu: (() -> [[CardContextAction]])?
    var onBeginDrag: (() -> ClipboardDragPayload?)?
    var onDragStarted: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onEndDrag: ((Bool) -> Void)?
    var dragPreviewURL: URL?
    var dragSymbolName = "doc.on.clipboard"
    var deferSelectionUntilMouseUp = false

    private var mouseDownPoint: NSPoint?
    private var pendingSelectionModifiers: NSEvent.ModifierFlags?
    private var dragProvider: (() -> ClipboardDragPayload?)?
    private var activeDragPayload: ClipboardDragPayload?
    private var localDragArtwork: NSImage?
    private var nativeDragStartPoint: NSPoint?
    private var dragMouseDownEvent: NSEvent?
    private var nativeEscapeMonitor: Any?
    private var nativeEscapeRequested = false
    private var nativeDragToken: UUID?
    private var nativeDragSession: NSDraggingSession?
    private var dragGesture: ContentDragGestureRecognizer?
    private weak var nativeDragShelf: ShelfPanel?
    private weak var responderBeforeNativeDrag: NSResponder?
    private var contextActions: [() -> Void] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let gesture = ContentDragGestureRecognizer(target: self, action: #selector(handlePointerGesture(_:)))
        gesture.delegate = self
        addGestureRecognizer(gesture)
        dragGesture = gesture
    }
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { nativeEscapeMonitor != nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { _ = cancelLocalCardDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    func pointerDown(with event: NSEvent) {
        _ = cancelLocalCardDrag()
        if event.clickCount == 2 {
            mouseDownPoint = nil
            pendingSelectionModifiers = nil
            dragProvider = nil
            onPaste?()
        } else if event.clickCount == 1 {
            dragMouseDownEvent = event
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            dragProvider = onBeginDrag
            if deferSelectionUntilMouseUp {
                // Keep the card in place while the user decides whether to
                // click it or drag it out of the panel.
                pendingSelectionModifiers = event.modifierFlags
            } else {
                onSelect?(event.modifierFlags)
            }
        }
    }

    func pointerDragged(with event: NSEvent, gesture: NSGestureRecognizer? = nil) {
        if let artwork = localDragArtwork, let payload = activeDragPayload,
           let shelf = window as? ShelfPanel {
            moveLocalCardDrag(in: shelf, artwork: artwork, payload: payload, event: event, gesture: gesture)
            return
        }
        guard let start = mouseDownPoint, activeDragPayload == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return }
        mouseDownPoint = nil
        guard let payload = dragProvider?(), !payload.writers.isEmpty else { return }
        pendingSelectionModifiers = nil
        activeDragPayload = payload
        let artwork = dragArtwork()
        if let shelf = window as? ShelfPanel {
            localDragArtwork = artwork
            shelf.localCardDragSource = self
            moveLocalCardDrag(in: shelf, artwork: artwork, payload: payload, event: event, gesture: gesture)
        } else {
            beginNativeDrag(payload, artwork: artwork, at: start, event: event, gesture: gesture)
        }
    }

    private func moveLocalCardDrag(in shelf: ShelfPanel, artwork: NSImage,
                                   payload: ClipboardDragPayload, event: NSEvent, gesture: NSGestureRecognizer?) {
        let windowPoint = event.locationInWindow
        let screenPoint = shelf.convertPoint(toScreen: windowPoint)
        if shelf.frame.contains(screenPoint) {
            // CoreDrag can change the shelf's backdrop while the pointer is
            // still over it. Track in-shelf drags with ordinary mouse events.
            shelf.showLocalCardDrag(artwork, at: windowPoint, ids: payload.sourceEntryIDs, scope: payload.reorderScope)
            return
        }

        shelf.clearLocalCardDragPreview()
        guard payload.exportsContent else { return }
        shelf.localCardDragSource = nil
        localDragArtwork = nil
        nativeDragStartPoint = screenPoint
        beginNativeDrag(payload, artwork: artwork, at: convert(windowPoint, from: nil), event: event, gesture: gesture)
    }

    private func beginNativeDrag(_ payload: ClipboardDragPayload, artwork: NSImage,
                                 at point: NSPoint, event: NSEvent, gesture: NSGestureRecognizer?) {
#if DEBUG
        Self.dragLogger.debug("drag requested writerTypes=\(payload.writers.map { String(describing: type(of: $0)) }.joined(separator: ","), privacy: .public)")
#endif
        // A gesture session starts at the current pointer, after the card
        // has travelled to the shelf boundary. Reusing the original press
        // position leaves that entire distance between cursor and preview.
        // The legacy event API instead uses the originating press as anchor.
        let startEvent = dragMouseDownEvent ?? event
        let startPoint: NSPoint
        if #available(macOS 27.0, *), let gesture {
            startPoint = gesture.location(in: self)
        } else {
            startPoint = convert(startEvent.locationInWindow, from: nil)
        }
        let items = payload.writers.enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 3)) * 4
            item.setDraggingFrame(
                NSRect(x: startPoint.x - 28 + offset, y: startPoint.y - 28 - offset,
                       width: 56, height: 56),
                contents: artwork
            )
            return item
        }
        nativeEscapeRequested = false
        let token = UUID()
        nativeDragToken = token
        removeNativeEscapeMonitor()
        nativeEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.trackNativeDragKey(event) ?? event
        }
        // Tell the shelf's event monitors that AppKit is taking over the drag.
        onDragStarted?()
        // Keep the source alive if SwiftUI refreshes or filters the card while
        // the native session is active. Its end callback must still reach us.
        nativeDragShelf = window as? ShelfPanel
        nativeDragShelf?.nativeCardDragSource = self
        traceNativeDrag(gesture == nil ? "begin-event" : "begin-gesture")
        let session: NSDraggingSession?
        if #available(macOS 27.0, *), let gesture {
            // AppKit owns the press/drag stream; activating an application or
            // moving keyboard focus here can invalidate that very gesture.
            session = beginDraggingSession(items: items, gesture: gesture, source: self)
        } else {
            prepareNativeDragKeyboardFocus()
            session = beginDraggingSession(with: items, event: startEvent, source: self)
        }
        guard nativeDragToken == token else { return }
        guard let session else { finishNativeDrag(operation: []); return }
        nativeDragSession = session
    }

    func prepareNativeDragKeyboardFocus() {
        // A nonactivating shelf borrows keyboard focus from the foreground
        // app. Native drag tracking must own that focus when the shelf moves
        // offscreen, so Escape reaches AppKit instead of the app underneath.
        responderBeforeNativeDrag = window?.firstResponder
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    func trackNativeDragKey(_ event: NSEvent) -> NSEvent {
        if event.keyCode == 53, !nativeEscapeRequested {
            nativeEscapeRequested = true
            traceNativeDrag("escape-observed")
        }
        // AppKit must receive Escape to end the real system drag, rather than
        // merely clearing our own preview or hiding the shelf.
        return event
    }

    private func removeNativeEscapeMonitor() {
        if let nativeEscapeMonitor { NSEvent.removeMonitor(nativeEscapeMonitor) }
        nativeEscapeMonitor = nil
    }

    func pointerUp(with event: NSEvent) {
        if localDragArtwork != nil {
            let ids = activeDragPayload?.sourceEntryIDs ?? []
            let drop = (window as? ShelfPanel)?.localCardDropAction(at: event.locationInWindow,
                                                                  ids: ids, scope: activeDragPayload?.reorderScope)
            _ = cancelLocalCardDrag()
            if !ids.isEmpty { drop?() }
            return
        }
        if let modifiers = pendingSelectionModifiers, activeDragPayload == nil {
            onSelect?(modifiers)
        }
        mouseDownPoint = nil
        dragMouseDownEvent = nil
        pendingSelectionModifiers = nil
        dragProvider = nil
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard gestureRecognizer === dragGesture, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return false }
        let point = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        return hitTest(point) === self
    }

    @objc private func handlePointerGesture(_ gesture: ContentDragGestureRecognizer) {
        guard gesture === dragGesture, let event = gesture.pointerEvent else { return }
        switch gesture.state {
        case .began: pointerDown(with: event)
        case .changed: pointerDragged(with: event, gesture: gesture)
        case .ended:
            if nativeDragToken == nil { pointerUp(with: event) }
        case .cancelled, .failed:
            // AppKit may cancel the initiating gesture during handoff. That
            // is not the native session's completion or a confirmed failure.
            if nativeDragToken == nil {
                _ = cancelLocalCardDrag()
                mouseDownPoint = nil
                dragMouseDownEvent = nil
                pendingSelectionModifiers = nil
                dragProvider = nil
            }
        default: break
        }
    }

    func cancelLocalCardDrag() -> Bool {
        guard localDragArtwork != nil else { return false }
        if let shelf = window as? ShelfPanel, shelf.localCardDragSource === self {
            shelf.localCardDragSource = nil
            shelf.clearLocalCardDragPreview()
        }
        localDragArtwork = nil
        activeDragPayload = nil
        mouseDownPoint = nil
        dragMouseDownEvent = nil
        pendingSelectionModifiers = nil
        dragProvider = nil
        return true
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        if context == .outsideApplication && activeDragPayload?.exportsContent == false { return [] }
        return .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Use this movement callback's screen coordinates. The session's
        // draggingLocation can still hold its initial value during startup.
        if !nativeEscapeRequested { onDragMoved?(screenPoint) }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // The shelf itself slides away during the drag, so a failed drop
        // should not send the drag image back to its former screen position.
        session.animatesToStartingPositionsOnCancelOrFail = false
#if DEBUG
        let types = (session.draggingPasteboard.pasteboardItems ?? []).map {
            $0.types.map(\.rawValue).joined(separator: ",")
        }.joined(separator: ";")
        Self.dragLogger.debug("drag began items=\(session.draggingPasteboard.pasteboardItems?.count ?? 0) types=\(types, privacy: .public)")
#endif
        // Use the mouse event that crossed the shelf boundary. AppKit's
        // initial drag location can still be zero until the first move.
        if let point = nativeDragStartPoint {
            nativeDragStartPoint = nil
            onDragMoved?(point)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        finishNativeDrag(operation: operation)
    }

    private func finishNativeDrag(operation: NSDragOperation) {
        traceNativeDrag("ended-\(operation.rawValue)")
        let didDrop = !operation.intersection([.copy, .move, .link, .generic]).isEmpty
        removeNativeEscapeMonitor()
        nativeDragSession = nil
        nativeDragToken = nil
        activeDragPayload = nil
        nativeDragStartPoint = nil
        dragMouseDownEvent = nil
        nativeEscapeRequested = false
        dragProvider = nil
        if let shelf = nativeDragShelf, shelf.nativeCardDragSource === self {
            shelf.nativeCardDragSource = nil
        }
        nativeDragShelf = nil
        if let window, window.firstResponder === self, let responderBeforeNativeDrag {
            window.makeFirstResponder(responderBeforeNativeDrag)
        }
        responderBeforeNativeDrag = nil
        // AppKit reports .none when Esc cancels the system drag. The panel
        // controller then animates the shelf back to its original position.
#if DEBUG
        Self.dragLogger.debug("drag ended operation=\(operation.rawValue)")
#endif
        onEndDrag?(didDrop)
    }

    private func traceNativeDrag(_ phase: String) {
#if DEBUG
        Self.dragLogger.notice("phase=\(phase, privacy: .public) sourceWindow=\(self.window?.windowNumber ?? 0) keyWindow=\(NSApp.keyWindow?.windowNumber ?? 0) gesture=\(self.dragGesture?.trackingDescription ?? "none", privacy: .public) escapeRequested=\(self.nativeEscapeRequested)")
#endif
    }

    deinit { removeNativeEscapeMonitor() }

    private func dragArtwork() -> NSImage {
        let source = dragPreviewURL.flatMap { url -> NSImage? in
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 112
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: thumbnail, size: NSSize(
                width: thumbnail.width, height: thumbnail.height
            ))
        }
            ?? NSImage(systemSymbolName: dragSymbolName, accessibilityDescription: nil)
        return NSImage(size: NSSize(width: 56, height: 56), flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            if let source, source.size.width > 0, source.size.height > 0 {
                let inset = rect.insetBy(dx: 5, dy: 5)
                let scale = min(inset.width / source.size.width, inset.height / source.size.height)
                let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
                source.draw(in: NSRect(
                    x: inset.midX - size.width / 2, y: inset.midY - size.height / 2,
                    width: size.width, height: size.height
                ))
            }
            return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let sections = makeContextMenu?()
        onContextSelect?()
        let menu = NSMenu()
        menu.autoenablesItems = false
        contextActions.removeAll()
        func append(_ action: CardContextAction, to menu: NSMenu) {
            let label = action.shortcut.map { "\(action.title)    \($0)" } ?? action.title
            let item = menu.addItem(withTitle: label, action: nil, keyEquivalent: "")
            item.isEnabled = action.isEnabled
            if !action.children.isEmpty {
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for child in action.children { append(child, to: submenu) }
                item.submenu = submenu
            } else {
                item.action = #selector(performContextAction(_:))
                item.target = self
                item.tag = contextActions.count
                contextActions.append(action.perform)
            }
        }
        if let sections {
            for section in sections where !section.isEmpty {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                for action in section { append(action, to: menu) }
            }
        } else {
            let copyItem = menu.addItem(withTitle: "复制", action: #selector(copyEntry), keyEquivalent: "")
            copyItem.target = self
            let deleteItem = menu.addItem(withTitle: "删除记录…", action: #selector(deleteEntry), keyEquivalent: "")
            deleteItem.target = self
        }
        return menu
    }

    @objc private func performContextAction(_ sender: NSMenuItem) {
        guard contextActions.indices.contains(sender.tag) else { return }
        contextActions[sender.tag]()
    }

    @objc private func copyEntry() {
        onCopy?()
    }

    @objc private func deleteEntry() {
        onDelete?()
    }
}
