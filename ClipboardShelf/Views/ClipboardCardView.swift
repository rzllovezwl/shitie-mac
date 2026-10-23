import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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
    let onOpenSource: () -> Void
    let onBeginDrag: () -> ClipboardDragPayload?
    let onDragStarted: () -> Void
    let onEndDrag: (Bool) -> Void
    @State private var previewResult: TextPreviewResult?

    private var previewMode: TextPreviewMode {
        TextPreviewMode.suggested(for: entry.textClassification, hasRichText: entry.hasRichText)
    }

    private var previewKey: String {
        "\(entry.id.uuidString)-\(formattedPreviewEnabled)-\(previewMode.rawValue)"
    }

    private var accessibilityDescription: String {
        let groupPrefix: String
        if let groupMembership {
            groupPrefix = "组内第\(groupMembership.position)项，共\(groupMembership.count)项，"
        } else {
            groupPrefix = ""
        }
        return groupPrefix + entry.title + "，单击选中，空格查看或收起详情，方向键切换，双击粘贴，按住拖到其他应用"
    }

    private var textScale: CGFloat {
        min(1.25, max(0.9, cardSize.height / 252))
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
                onBeginDrag: onBeginDrag,
                onDragStarted: onDragStarted,
                onEndDrag: onEndDrag,
                dragPreviewURL: entry.kind == .image ? imageURL : thumbnailURL,
                dragSymbolName: entry.kind == .link ? "link" : "doc.on.clipboard",
                deferSelectionUntilMouseUp: true
            )
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
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onBeginDrag: () -> ClipboardDragPayload?
    let onDragStarted: () -> Void
    let onEndDrag: (Bool) -> Void

    private var textScale: CGFloat { min(1.25, max(0.9, cardSize.height / 252)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * textScale) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 13 * textScale, weight: .semibold))
                Text("\(entry.groupMemberIDs.count) 项分组")
                    .fontWeight(.semibold)
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
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11 * textScale, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(isExpanded ? "收起" : "展开")
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
                onBeginDrag: onBeginDrag, onDragStarted: onDragStarted,
                onEndDrag: onEndDrag,
                dragSymbolName: "square.stack.3d.up",
                deferSelectionUntilMouseUp: true
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.groupMemberIDs.count) 项分组，单击\(isExpanded ? "收起" : "展开")，双击粘贴，按住拖到其他应用")
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
    var onBeginDrag: (() -> ClipboardDragPayload?)? = nil
    var onDragStarted: (() -> Void)? = nil
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
        view.onBeginDrag = onBeginDrag
        view.onDragStarted = onDragStarted
        view.onEndDrag = onEndDrag
        view.dragPreviewURL = dragPreviewURL
        view.dragSymbolName = dragSymbolName
        view.deferSelectionUntilMouseUp = deferSelectionUntilMouseUp
        view.toolTip = onBeginDrag == nil ? nil : "按住卡片拖到其他应用"
    }
}

final class CardInteractionView: NSView, NSDraggingSource {
    var onSelect: ((NSEvent.ModifierFlags) -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onBeginDrag: (() -> ClipboardDragPayload?)?
    var onDragStarted: (() -> Void)?
    var onEndDrag: ((Bool) -> Void)?
    var dragPreviewURL: URL?
    var dragSymbolName = "doc.on.clipboard"
    var deferSelectionUntilMouseUp = false

    private var mouseDownPoint: NSPoint?
    private var pendingSelectionModifiers: NSEvent.ModifierFlags?
    private var dragProvider: (() -> ClipboardDragPayload?)?
    private var activeDragPayload: ClipboardDragPayload?
    private var draggingStarted = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            mouseDownPoint = nil
            pendingSelectionModifiers = nil
            dragProvider = nil
            onPaste?()
        } else if event.clickCount == 1 {
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

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !draggingStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return }
        mouseDownPoint = nil
        guard let payload = dragProvider?(), !payload.writers.isEmpty else { return }
        pendingSelectionModifiers = nil
        draggingStarted = true
        activeDragPayload = payload

        let artwork = dragArtwork()
        let items = payload.writers.enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 3)) * 4
            item.setDraggingFrame(
                NSRect(x: start.x - 28 + offset, y: start.y - 28 - offset,
                       width: 56, height: 56),
                contents: artwork
            )
            return item
        }
        _ = beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if let modifiers = pendingSelectionModifiers, !draggingStarted {
            onSelect?(modifiers)
        }
        mouseDownPoint = nil
        pendingSelectionModifiers = nil
        dragProvider = nil
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStarted?()
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        activeDragPayload = nil
        draggingStarted = false
        dragProvider = nil
        onEndDrag?(operation != [])
    }

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

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "复制", action: #selector(copyEntry), keyEquivalent: "")
        copyItem.target = self
        let deleteItem = menu.addItem(withTitle: "删除记录…", action: #selector(deleteEntry), keyEquivalent: "")
        deleteItem.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyEntry() {
        onCopy?()
    }

    @objc private func deleteEntry() {
        onDelete?()
    }
}
