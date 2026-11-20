import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import UniformTypeIdentifiers

private struct ToolbarHintBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct TranslationRequest: Identifiable {
    let id = UUID()
    let text: String
}

private struct ContentToolRequest: Identifiable {
    let id = UUID()
    let text: String
    let isLink: Bool
}

enum ClipboardDetailContext { case history, staging }

/// Reuse the clipboard's bubble, content renderer and image zoom controls while
/// keeping staging items independent of the clipboard history database.
struct StagingDetailPreviewView: View {
    @ObservedObject var model: AppController
    @ObservedObject var session: StagingShelfPreviewSession
    let tail: PreviewTail
    let backingScale: CGFloat
    let onCopy: () -> Void
    let onRemove: () -> Void
    let onKeyDown: (NSEvent) -> Bool
    let onClose: () -> Void

    var body: some View {
        let entry = session.entry
        ClipboardPreviewSurface(tail: tail, onKeyDown: handleKey) {
            ClipboardDetailView(
                entry: entry, backingScale: backingScale,
                imageURL: entry.kind == .image ? entry.filePath.map(URL.init(fileURLWithPath:)) : nil,
                thumbnailURL: nil, richTextFiles: RichTextSourceFiles(rtf: nil, html: nil, rtfd: nil),
                fileHasSavedCopy: false, savedCopyName: nil,
                fileReferenceAvailable: true, originalFileReferenceAvailable: true,
                canAuthorizeWeChatFolder: false, loadFileReferenceImage: { nil },
                makeFilePreviewAccess: { session.payload.access },
                onCopy: onCopy, onSaveImageToFile: { model.saveStagingImageToFile(session.payload) },
                canRecognize: session.canUseImage, isRecognizing: session.isRecognizing,
                initiallyShowsOCR: false, initiallyShowsTools: false,
                shortcuts: model.shortcuts, previewActionRequest: session.actionRequest, ocrError: session.ocrError,
                onRecognize: { session.recognize() }, onCopyOCRText: { model.copyRecognizedText($0) },
                onCopyTranslatedText: { model.copyTranslatedText($0) }, onCopyProcessedText: { model.copyProcessedText($0) },
                canAnnotateScreenshot: session.canUseImage,
                onAnnotateScreenshot: { model.annotateStagingImage(session.payload) },
                canPin: session.canUseImage, isPinned: model.isPinnedImage(entry),
                onPin: { model.pinStagingImage(session.payload) }, onUnpin: { model.unpinImage(entry) },
                onRevealOriginalFile: {
                    guard case .file(let url) = session.payload.content else { return false }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    return true
                },
                onRelinkFile: {}, onAuthorizeWeChatFolder: {}, onSaveFileCopy: {}, onRemoveFileCopy: {},
                onEditText: { model.editStagingText(session.payload) }, onDelete: onRemove, onImagePreviewAppear: {},
                onPopoverVisibilityChange: { _ in }, onClose: onClose, context: .staging
            )
            .id(entry.id)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if !event.isARepeat {
            for action in [AppShortcutAction.recognizeImageText, .translateScreenshot, .annotateImage,
                           .saveImageToFile, .togglePinImage] where model.shortcut(for: action).matches(
                            keyCode: event.keyCode, modifiers: event.modifierFlags) {
                switch action {
                case .recognizeImageText, .translateScreenshot:
                    if session.canUseImage || (action == .translateScreenshot && session.entry.kind == .text) {
                        session.request(action)
                    }
                case .annotateImage:
                    if session.canUseImage { model.annotateStagingImage(session.payload) }
                    else if session.entry.isEditableText { model.editStagingText(session.payload) }
                case .saveImageToFile:
                    if session.canUseImage { model.saveStagingImageToFile(session.payload) }
                case .togglePinImage:
                    if model.isPinnedImage(session.entry) { model.unpinImage(session.entry) }
                    else if session.canUseImage && model.pinStagingImage(session.payload) { onClose() }
                default: break
                }
                return true
            }
        }
        return onKeyDown(event)
    }
}

final class StagingDetailHostingView: NSHostingView<StagingDetailPreviewView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let backingScale: CGFloat
    let imageURL: URL?
    let thumbnailURL: URL?
    let richTextFiles: RichTextSourceFiles
    let fileHasSavedCopy: Bool
    let savedCopyName: String?
    let fileReferenceAvailable: Bool
    let originalFileReferenceAvailable: Bool
    let canAuthorizeWeChatFolder: Bool
    let loadFileReferenceImage: () async -> NSImage?
    let makeFilePreviewAccess: () -> FilePreviewAccess?
    let onCopy: () -> Void
    let onSaveImageToFile: () -> Void
    let canRecognize: Bool
    let isRecognizing: Bool
    let initiallyShowsOCR: Bool
    let initiallyShowsTools: Bool
    let shortcuts: [AppShortcutAction: AppShortcut]
    let previewActionRequest: ClipboardPreviewActionRequest?
    let ocrError: String?
    let onRecognize: () -> Void
    let onCopyOCRText: (String) -> Void
    let onCopyTranslatedText: (String) -> Bool
    let onCopyProcessedText: (String) -> Bool
    let canAnnotateScreenshot: Bool
    let onAnnotateScreenshot: () -> Void
    let canPin: Bool
    let isPinned: Bool
    let onPin: () -> Bool
    let onUnpin: () -> Void
    let onRevealOriginalFile: () -> Bool
    let onRelinkFile: () -> Void
    let onAuthorizeWeChatFolder: () -> Void
    let onSaveFileCopy: () -> Void
    let onRemoveFileCopy: () -> Void
    let onEditText: () -> Void
    let onDelete: () -> Void
    let onImagePreviewAppear: () -> Void
    let onPopoverVisibilityChange: (Bool) -> Void
    let onClose: () -> Void
    var context: ClipboardDetailContext = .history
    @State private var revealFailed = false
    @State private var previewMode: TextPreviewMode = .original
    @State private var codeLanguage = "自动"
    @State private var previewResult: TextPreviewResult?
    @State private var selectedFormat = ""
    @State private var fileReferenceImage: NSImage?
    @State private var savedImage: NSImage?
    @State private var imageZoomAction: ImageZoomAction?
    @State private var imageZoomPercentage = 100
    @State private var showsOCR = false
    @State private var ocrStartedAt = Date()
    @State private var showsMoreInfo = false
    @State private var hoveredToolbarHint: String?
    @State private var selectedPreviewText = ""
    @State private var translationRequest: TranslationRequest?
    @State private var contentToolRequest: ContentToolRequest?
    @State private var handledPreviewActionID: UUID?
    @State private var translatesAfterRecognition = false

    private func shortcutHint(_ action: AppShortcutAction) -> String {
        (shortcuts[action] ?? action.defaultShortcut).displayName
    }

    private func handlePreviewAction() {
        guard let request = previewActionRequest, request.entryID == entry.id,
              request.id != handledPreviewActionID else { return }
        handledPreviewActionID = request.id
        switch request.action {
        case .saveImageToFile:
            if entry.isScreenRecording { onSaveImageToFile() }
        case .recognizeImageText:
            guard canRecognize else { return }
            showsOCR = true
            if entry.ocrText == nil && !isRecognizing { onRecognize() }
        case .translateScreenshot:
            translatePreview()
        default: break
        }
    }

    private var isImageFileReference: Bool {
        guard entry.kind == .fileReference else { return false }
        let type = entry.fileType.flatMap(UTType.init)
            ?? UTType(filenameExtension: URL(fileURLWithPath: entry.fileName ?? "").pathExtension)
        return type?.conforms(to: .image) == true
    }

    private var showsImageZoom: Bool {
        entry.kind == .image || isImageFileReference
    }

    private var usesImageToolbar: Bool {
        showsImageZoom || entry.kind == .unavailableImage
    }

    private var canTranslateImage: Bool {
        showsImageZoom && (canRecognize || entry.ocrText?.isEmpty == false)
    }

    private var previewKey: String {
        "\(entry.id.uuidString)-\(entry.digest)-\(previewMode.rawValue)-\(codeLanguage)"
    }

    private var imageSourceKey: String {
        "\(entry.id.uuidString)-\(entry.kind.rawValue)-\(entry.imageFileName ?? "")-\(entry.fileCopyName ?? "")"
    }

    private var suggestedPreviewMode: TextPreviewMode {
        TextPreviewMode.suggested(for: entry.textClassification, hasRichText: entry.hasRichText)
    }

    private func selectSuggestedPreview() {
        previewMode = suggestedPreviewMode
        codeLanguage = entry.textClassification.codeLanguage ?? "自动"
    }

    private var detailTitle: String {
        entry.kind == .unavailableImage ? "未保存图片" :
        entry.kind == .image ? "图片详情" :
        entry.isScreenRecording ? "录屏预览" :
        entry.kind == .fileReference ? "文件位置引用" :
        entry.kind == .link ? "链接详情" : "\(entry.textClassification.label)详情"
    }

    private func togglePin() {
        if isPinned {
            onUnpin()
        } else if onPin() {
            // Keep the shelf open; only dismiss this preview after pinning succeeds.
            onClose()
        }
    }

    private func toolbarButton(
        _ title: String, symbol: LucideSymbol, compact: Bool,
        hint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        toolbarButton(title, compact: compact, hint: hint, action: action) {
            LucideIcon(symbol, size: compact ? 17 : 13)
        }
    }

    private func toolbarButton<Icon: View>(
        _ title: String, compact: Bool, hint: String? = nil,
        action: @escaping () -> Void, @ViewBuilder icon: () -> Icon
    ) -> some View {
        let hoverHint = hint ?? title
        let button = Button(action: action) {
            if usesImageToolbar {
                icon()
                    .frame(width: 32, height: 26)
                    .contentShape(Rectangle())
            } else if compact {
                icon()
                    .frame(width: 17, height: 17)
            } else {
                Label { Text(title) } icon: { icon() }
            }
        }
        return Group {
            if usesImageToolbar {
                button.buttonStyle(.plain)
            } else {
                button.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .fixedSize()
        .accessibilityLabel(title)
        .help(hoverHint)
        .anchorPreference(key: ToolbarHintBoundsPreferenceKey.self, value: .bounds) {
            [hoverHint: $0]
        }
        .onHover { isHovering in
            if isHovering {
                hoveredToolbarHint = hoverHint
            } else if hoveredToolbarHint == hoverHint {
                hoveredToolbarHint = nil
            }
        }
    }

    private var toolbarSeparator: some View {
        Rectangle()
            .fill(.primary.opacity(0.16))
            .frame(width: 1, height: 15)
            .accessibilityHidden(true)
    }

    private func toolbarHintTextWidth(_ text: String, availableWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let naturalWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return min(naturalWidth, max(32, min(300, availableWidth - 16) - 20))
    }

    private var translationCandidate: String? {
        let source: String?
        if showsImageZoom {
            source = entry.ocrText
        } else if entry.kind == .text {
            let selection = selectedPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
            source = selection.isEmpty ? (previewResult?.text.string ?? entry.text) : selection
        } else {
            source = nil
        }
        let text = source?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func translatePreview() {
        if showsImageZoom {
            guard canTranslateImage else { return }
            showsOCR = true
            if entry.ocrText == nil {
                translatesAfterRecognition = true
                if !isRecognizing { onRecognize() }
                return
            }
        }
        presentTranslation()
    }

    private func presentTranslation() {
        guard let translationCandidate else { return }
        translationRequest = TranslationRequest(text: translationCandidate)
    }

    private func presentContentTools() {
        let isLink = entry.kind == .link && entry.webURL != nil
        let source: String?
        if showsOCR {
            source = entry.ocrText
        } else if isLink {
            source = entry.text ?? entry.webURL?.absoluteString
        } else if entry.kind == .text {
            source = selectedPreviewText.isEmpty ? entry.text : selectedPreviewText
        } else {
            source = nil
        }
        guard let source, !source.isEmpty else { return }
        contentToolRequest = ContentToolRequest(text: source, isLink: isLink)
    }

    @ViewBuilder
    private func contentToolsPopover(for request: ContentToolRequest) -> some View {
        if request.isLink {
            if let cleaner = URLQueryCleaner(request.text) {
                ClipboardLinkCleanerView(cleaner: cleaner, onCopy: onCopyProcessedText)
            } else {
                Text("这条内容不是有效的网页链接。")
                    .padding(18)
            }
        } else {
            ClipboardContentToolsView(
                sourceText: request.text,
                classification: entry.textClassification,
                hasRichText: entry.hasRichText,
                onCopy: onCopyProcessedText
            )
        }
    }

    @ViewBuilder
    private var textPreviewContent: some View {
        if let previewResult {
            TextPreviewView(content: previewResult.text,
                            onTextSelectionChange: { selectedPreviewText = $0 }) {
                selectedFormat = $0
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    previewResult.actualRichText ? Color.white : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            if let notice = previewResult.notice {
                Text(notice)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
        } else {
            ProgressView("正在准备预览…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var ocrResultContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("识别文字")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button("重新识别", action: onRecognize)
                    .help("识别文字（\(shortcutHint(.recognizeImageText))）")
                    .disabled(isRecognizing || !canRecognize)
                Button("复制全文") {
                    if let text = entry.ocrText { onCopyOCRText(text) }
                }
                .disabled(isRecognizing || entry.ocrText?.isEmpty != false)
                Button("文本工具", action: presentContentTools)
                    .disabled(isRecognizing || entry.ocrText?.isEmpty != false)
                    .popover(item: $contentToolRequest, arrowEdge: .bottom) { request in
                        contentToolsPopover(for: request)
                    }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if isRecognizing {
                ZStack {
                    Color.primary.opacity(0.035)
                    if let image = savedImage ?? fileReferenceImage {
                        Image(nsImage: image).resizable().scaledToFit().opacity(0.6)
                    }
                    ScanLoadingOverlay(message: "正在识别图片文字…")
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                TimelineView(.periodic(from: ocrStartedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(ocrStartedAt)))
                    VStack(spacing: 9) {
                        if elapsed >= 5 {
                            Text("首次准备系统识别模型，已等待 \(elapsed) 秒；关闭预览后会继续识别")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if let ocrError {
                Spacer()
                Text(ocrError)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if let text = entry.ocrText, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            } else {
                Spacer()
                Text(entry.ocrText == nil ? "点击“重新识别”提取图片文字。" : "没有识别到文字。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        GeometryReader { geometry in
        let labeledToolbarWidth: CGFloat = entry.isEditableText ? 650 : 600
        let compactToolbar = usesImageToolbar || geometry.size.width < labeledToolbarWidth
        let showsToolbarTitle = !showsImageZoom ||
            geometry.size.width >= (isImageFileReference ? 500 : 390)
        let compactSpacing: CGFloat = usesImageToolbar ? 4 : 5
        let toolbarSpacing: CGFloat = showsToolbarTitle ? (compactToolbar ? compactSpacing : 8) : 3
        let showsRecognitionButton = showsImageZoom && canRecognize
        let showsTranslationButton = entry.kind == .text || canTranslateImage
        let expandedHeight = min(142, max(65, geometry.size.height * 0.24))
        let imageZoomVisible = showsImageZoom && !showsOCR
        let reservedHeight: CGFloat = imageZoomVisible
            ? (entry.kind == .fileReference ? 155 : 145)
            : (entry.kind == .fileReference ? 132 : 120)
        let viewportHeight = max(80, geometry.size.height - reservedHeight
                                 - (showsMoreInfo ? expandedHeight : 0))
        let imageViewportSize = CGSize(width: geometry.size.width, height: viewportHeight)
        VStack(alignment: .leading, spacing: showsImageZoom ? 8 : 12) {
            HStack(spacing: toolbarSpacing) {
                HStack(spacing: 6) {
                    ClipboardContentTypeIcon(entry: entry, size: 16)
                    if showsToolbarTitle {
                        Text(detailTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(detailTitle)
                .layoutPriority(1)
                Spacer(minLength: 2)
                toolbarButton(
                    showsOCR ? "复制识别文字" : "复制",
                    symbol: .copy, compact: compactToolbar
                ) {
                    if showsOCR, let text = entry.ocrText {
                        onCopyOCRText(text)
                    } else {
                        onCopy()
                    }
                }
                .disabled(showsOCR
                          ? (isRecognizing || entry.ocrText?.isEmpty != false)
                          : entry.kind == .unavailableImage)
                if showsImageZoom || entry.isScreenRecording {
                    toolbarButton("保存为…", symbol: .download, compact: compactToolbar,
                                  hint: "保存为…（\(shortcutHint(.saveImageToFile))）",
                                  action: onSaveImageToFile)
                        .disabled(entry.isScreenRecording ? !fileReferenceAvailable : !canAnnotateScreenshot)
                }
                if usesImageToolbar { toolbarSeparator }

                if entry.isEditableText {
                    toolbarButton("编辑", symbol: .pencil, compact: compactToolbar,
                                  hint: "编辑原文（\(shortcutHint(.annotateImage))）", action: onEditText)
                }
                if showsRecognitionButton {
                    toolbarButton(
                        showsOCR ? "查看图片" : "识别文字",
                        symbol: showsOCR ? .image : .scanSearch,
                        compact: compactToolbar,
                        hint: showsOCR ? "查看图片" : "识别文字（\(shortcutHint(.recognizeImageText))）"
                    ) {
                        showsOCR.toggle()
                        if showsOCR && entry.ocrText == nil && !isRecognizing {
                            onRecognize()
                        }
                    }
                }
                if showsTranslationButton {
                    toolbarButton("翻译", symbol: .languages,
                                  compact: compactToolbar,
                                  hint: "翻译（\(shortcutHint(.translateScreenshot))）",
                                  action: translatePreview)
                        .disabled(showsImageZoom ? isRecognizing : translationCandidate == nil)
                        .popover(item: $translationRequest, arrowEdge: .bottom) { request in
                            TranslationPreviewView(sourceText: request.text,
                                                   onCopyTranslation: onCopyTranslatedText)
                        }
                }
                if entry.kind == .text || entry.kind == .link {
                    toolbarButton(entry.kind == .link ? "清理链接" : "文本工具",
                                  symbol: entry.kind == .link ? .link : .braces,
                                  compact: compactToolbar,
                                  action: presentContentTools)
                        .popover(item: $contentToolRequest, arrowEdge: .bottom) { request in
                            contentToolsPopover(for: request)
                        }
                }
                if canAnnotateScreenshot {
                    toolbarButton("标注图片", symbol: .squarePen,
                                  compact: compactToolbar,
                                  hint: "标注图片（\(shortcutHint(.annotateImage))）",
                                  action: onAnnotateScreenshot)
                }
                if usesImageToolbar && (showsRecognitionButton || showsTranslationButton || canAnnotateScreenshot) {
                    toolbarSeparator
                }

                if showsImageZoom && (canPin || isPinned) {
                    toolbarButton(
                        isPinned ? "取消钉住" : "钉在桌面",
                        symbol: isPinned ? .pinOff : .pin,
                        compact: compactToolbar,
                        action: togglePin
                    )
                }
                if entry.kind == .fileReference && context == .history && !entry.isScreenRecording {
                    if !fileHasSavedCopy
                        && (entry.sourceAppName == "微信" || !fileReferenceAvailable) {
                        toolbarButton("重新关联…", symbol: .link,
                                      compact: compactToolbar, action: onRelinkFile)
                    }
                    toolbarButton(
                        fileHasSavedCopy ? "更新副本…" : "保存副本…",
                        compact: compactToolbar,
                        hint: fileHasSavedCopy
                            ? "更新本地副本，原文件移动后仍可使用"
                            : "保存本地副本，原文件移动后仍可复制或粘贴",
                        action: onSaveFileCopy
                    ) {
                        if isImageFileReference {
                            Image(systemName: "externaldrive.badge.plus").font(.system(size: 16))
                        } else {
                            LucideIcon(.download, size: compactToolbar ? 17 : 13)
                        }
                    }
                    if fileHasSavedCopy {
                        toolbarButton("移除副本", compact: compactToolbar,
                                      hint: "移除 ClipHoook 保存的文件副本，继续引用原文件",
                                      action: onRemoveFileCopy) {
                            Image(systemName: "externaldrive.badge.minus")
                                .font(.system(size: compactToolbar ? 16 : 13))
                        }
                    }
                }
                toolbarButton(context == .staging ? "移出暂存箱" : "删除", symbol: .trash,
                              compact: compactToolbar, action: onDelete)
                if usesImageToolbar { toolbarSeparator }
                toolbarButton("关闭", symbol: .x, compact: compactToolbar, action: onClose)
            }
            .overlayPreferenceValue(ToolbarHintBoundsPreferenceKey.self) { bounds in
                GeometryReader { hintGeometry in
                    if let hoveredToolbarHint,
                       let buttonBounds = bounds[hoveredToolbarHint] {
                        let buttonRect = hintGeometry[buttonBounds]
                        let textWidth = toolbarHintTextWidth(
                            hoveredToolbarHint, availableWidth: hintGeometry.size.width
                        )
                        let hintWidth = textWidth + 20
                        let hintX = min(
                            max(8, buttonRect.midX - hintWidth / 2),
                            hintGeometry.size.width - hintWidth - 8
                        )
                        Text(hoveredToolbarHint)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(width: textWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.regularMaterial,
                                        in: RoundedRectangle(cornerRadius: 7,
                                                             style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
                            .offset(x: hintX, y: buttonRect.maxY + 5)
                            .accessibilityHidden(true)
                    }
                }
                .allowsHitTesting(false)
            }
            .zIndex(1)

            Group {
                if showsImageZoom && showsOCR {
                    ocrResultContent
                } else if entry.kind == .image,
                   let image = savedImage {
                    ZoomableImageView(image: image, entryID: entry.id,
                                      backingScale: backingScale,
                                      initialViewportSize: imageViewportSize,
                                      zoomAction: imageZoomAction) {
                        imageZoomPercentage = Int(($0 * 100).rounded())
                    }
                        .onAppear(perform: onImagePreviewAppear)
                        .accessibilityLabel("图片预览，可双指捏合缩放")
                } else if entry.kind == .image {
                    Text("图片文件不可用")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entry.kind == .unavailableImage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                        Text("这张图片未保存")
                            .font(.system(size: 17, weight: .semibold))
                        Text("微信这次复制没有提供可读取的图片内容，因此这里只显示占位符。")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isImageFileReference, let fileReferenceImage {
                    ZoomableImageView(
                        image: fileReferenceImage, entryID: entry.id,
                        backingScale: backingScale,
                        initialViewportSize: imageViewportSize,
                        zoomAction: imageZoomAction,
                        onZoomChange: { imageZoomPercentage = Int(($0 * 100).rounded()) }
                    )
                    .id(imageSourceKey)
                    .onAppear(perform: onImagePreviewAppear)
                    .accessibilityLabel("图片文件预览，可双指捏合缩放")
                } else if entry.kind == .fileReference {
                    VStack(spacing: 8) {
                        FileQuickLookPreview(
                            entry: entry, thumbnailURL: thumbnailURL,
                            fileReferenceAvailable: fileReferenceAvailable,
                            makePreviewAccess: makeFilePreviewAccess,
                            onInteractivePreviewAppear: onImagePreviewAppear
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(fileHasSavedCopy
                            ? originalFileReferenceAvailable
                                ? "已保存本地副本；原文件也可访问，可移除副本。"
                                : canAuthorizeWeChatFolder
                                    ? "已保存本地副本；原文件不可访问。授权微信文件夹后可移除副本。"
                                    : "已保存本地副本；原文件不可访问，复制和粘贴时使用副本。"
                            : fileReferenceAvailable
                                ? "仅记录原文件位置，尚未保存文件副本。"
                                : entry.sourceAppName == "微信"
                                    ? "微信文件夹尚未授权，或原文件已失效。授权后可直接拖动文件，不保存副本。"
                                    : "原文件无法供其他应用粘贴；请重新关联可访问的文件。")
                            .font(.caption)
                            .foregroundStyle(originalFileReferenceAvailable ? Color.secondary : Color.orange)
                            .multilineTextAlignment(.center)
                        if !originalFileReferenceAvailable && canAuthorizeWeChatFolder {
                            Button("授权微信文件夹…", action: onAuthorizeWeChatFolder)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                } else if entry.kind == .link, let url = entry.webURL {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(url.host ?? "网页链接")
                                .font(.system(size: 15, weight: .semibold))
                            Link(destination: url) {
                                Text(String((entry.text ?? url.absoluteString)
                                    .trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_192)))
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.accentColor)
                                    .underline()
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityLabel("打开链接：\(url.absoluteString)")
                            Text("点击网址，在默认浏览器中打开")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Picker("预览方式", selection: $previewMode) {
                                if entry.hasRichText || entry.textClassification == .markdown {
                                    Text("原格式").tag(TextPreviewMode.original)
                                }
                                if entry.textClassification != .markdown {
                                    Text("原文").tag(TextPreviewMode.plain)
                                }
                                Text("Markdown").tag(TextPreviewMode.markdown)
                                Text("代码").tag(TextPreviewMode.code)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize(horizontal: true, vertical: false)
                            .clipShape(Capsule())
                            if previewMode == .code {
                                Picker("语言", selection: $codeLanguage) {
                                    ForEach(TextPreviewRenderer.codeLanguages, id: \.self) {
                                        Text($0)
                                    }
                                }
                                .frame(width: 115)
                                .accessibilityLabel("代码语言")
                            }
                            Spacer(minLength: 0)
                        }
                        textPreviewContent
                        Text("\(previewResult?.actualRichText == true ? "原始格式" : "预览样式")：\(selectedFormat)")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .help(selectedFormat)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: viewportHeight)
            .clipShape(RoundedRectangle(cornerRadius: showsImageZoom ? 10 : 0,
                                        style: .continuous))

            if imageZoomVisible {
                HStack(spacing: 8) {
                    Button("缩小") { imageZoomAction = ImageZoomAction(kind: .outwards) }
                    Button("适合窗口") { imageZoomAction = ImageZoomAction(kind: .fit) }
                    Button("100%") { imageZoomAction = ImageZoomAction(kind: .actualSize) }
                    Button("放大") { imageZoomAction = ImageZoomAction(kind: .inwards) }
#if DEBUG
                    Text("当前显示 \(imageZoomPercentage)%")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
#endif
                    Spacer()
                    if geometry.size.width >= 530 {
                        Text("也可用触控板双指缩放")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(savedImage == nil && fileReferenceImage == nil)
            }

            metadata(expandedHeight: expandedHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(showsImageZoom ? 14 : 18)
        .animation(.easeInOut(duration: 0.22), value: showsMoreInfo)
        .task(id: previewKey) {
            guard entry.kind == .text || (entry.kind == .link && entry.webURL == nil) else { return }
            let mode = previewMode.renderingMode(
                for: entry.textClassification, hasRichText: entry.hasRichText
            )
            previewResult = nil
            selectedFormat = ""
            let result = await TextPreviewRenderer.render(
                mode: mode, raw: entry.text ?? "内容文件不可用",
                files: richTextFiles, language: codeLanguage
            )
            guard !Task.isCancelled else { return }
            previewResult = result
        }
        .task(id: imageSourceKey) {
            let nextSavedImage = entry.kind == .image
                ? imageURL.flatMap(NSImage.init(contentsOf:)) : nil
            let nextFileReferenceImage = isImageFileReference
                ? (await loadFileReferenceImage()
                   ?? thumbnailURL.flatMap(NSImage.init(contentsOf:)))
                : nil
            guard !Task.isCancelled else { return }
            savedImage = nextSavedImage
            fileReferenceImage = nextFileReferenceImage
            imageZoomAction = nil
            imageZoomPercentage = 100
        }
        .onChange(of: entry.id) { _, _ in
            revealFailed = false
            showsMoreInfo = false
            showsOCR = initiallyShowsOCR
            hoveredToolbarHint = nil
            selectedPreviewText = ""
            translationRequest = nil
            contentToolRequest = nil
            translatesAfterRecognition = false
            selectSuggestedPreview()
        }
        .onChange(of: entry.textRevision) { _, _ in
            selectedPreviewText = ""
            translationRequest = nil
            contentToolRequest = nil
            selectSuggestedPreview()
        }
        .onChange(of: isRecognizing) { _, active in
            if active { ocrStartedAt = .now }
        }
        .onChange(of: ocrError) { _, error in
            if error != nil { translatesAfterRecognition = false }
        }
        .onChange(of: previewActionRequest?.id) { _, _ in handlePreviewAction() }
        .onChange(of: entry.ocrText) { _, text in
            guard translatesAfterRecognition, text != nil else { return }
            translatesAfterRecognition = false
            if showsOCR { presentTranslation() }
        }
        .onChange(of: showsOCR) { _, active in
            if active {
                onImagePreviewAppear()
            } else {
                translatesAfterRecognition = false
            }
        }
        .onChange(of: isPinned) { _, _ in hoveredToolbarHint = nil }
        .onChange(of: translationRequest != nil || contentToolRequest != nil) { _, visible in
            onPopoverVisibilityChange(visible)
        }
        .onDisappear { onPopoverVisibilityChange(false) }
        .onAppear {
            selectSuggestedPreview()
            showsOCR = initiallyShowsOCR
            if isRecognizing { ocrStartedAt = .now }
            if initiallyShowsTools { presentContentTools() }
            handlePreviewAction()
        }
    }

    private func metadata(expandedHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SourceAppIconView(
                    bundleID: entry.sourceAppBundleID,
                    name: entry.sourceAppName,
                    size: 16
                )
                Text("来源：\(entry.sourceAppName ?? "未知")")
                    .lineLimit(1)
                    .truncationMode(.tail)
                if entry.kind == .fileReference && fileHasSavedCopy {
                    SavedFileCopyBadge(fontSize: 10)
                }
                Spacer(minLength: 0)
                Text(ClipboardTimeLabel.detail(entry.createdAt))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(entry.createdAt.formatted(date: .complete, time: .standard))
            }
            .frame(minHeight: 18)
            if entry.kind == .unavailableImage {
                Text("保存状态：仅记录图片在原复制中的位置，没有图片内容")
            } else if entry.kind == .fileReference {
                HStack(spacing: 12) {
                    Button(action: revealInFinder) {
                        Text(entry.fileName ?? "文件")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color.accentColor)
                    .help("在访达中显示：\(entry.fileName ?? "文件")")
                    Button(action: revealInFinder) {
                        HStack(spacing: 3) {
                            Text("在访达中显示")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.link)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Color.accentColor)
                    .help("在访达中显示原文件")
                }
                .frame(minHeight: 18)
                if revealFailed {
                    Text("原文件已移动、删除或无法访问，无法在访达中显示。")
                        .foregroundStyle(.orange)
                }
            }
            Button {
                showsMoreInfo.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showsMoreInfo ? 90 : 0))
                    Text("更多信息")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsMoreInfo ? "已展开" : "已折叠")
            .frame(minHeight: 18)
            if showsMoreInfo {
                ScrollView {
                    moreMetadata
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: expandedHeight)
                .padding(.top, 4)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .layoutPriority(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func revealInFinder() {
        revealFailed = !onRevealOriginalFile()
    }

    private var moreMetadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entry.kind == .fileReference {
                Text("原位置：\(entry.filePath ?? "未知")")
                    .textSelection(.enabled)
                Text(fileHasSavedCopy ? "保存方式：位置引用 + 本地副本" : "保存方式：仅位置引用")
                if let savedCopyName { Text("副本文件：\(savedCopyName)") }
            } else if entry.hasRichText {
                Text("保留格式：复制时优先提供富文本，目标应用不支持时可用纯文本。")
            }
            Text("最近复制：\(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
            if let firstCopiedAt = entry.firstCopiedAt {
                Text("首次复制：\(firstCopiedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            if let copyCount = entry.copyCount {
                Text("\(entry.firstCopiedAt == nil ? "已记录复制次数" : "复制次数")：\(copyCount)")
            }
            Text("\(entry.kind == .fileReference ? "原文件大小" : "大小")：\(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))")
        }
    }
}

/// The system translation popover chooses its own target language. This view
/// keeps the same on-device Translation framework while making the language
/// pair explicit and editable.
struct TranslationPreviewView: View {
    let sourceText: String
    let onCopyTranslation: (String) -> Bool

    var body: some View {
        if #available(macOS 15.0, *) {
            NativeTranslationPreviewView(sourceText: sourceText, onCopyTranslation: onCopyTranslation)
        } else if #available(macOS 14.4, *) {
            LegacyTranslationPreviewView(sourceText: sourceText, onCopyTranslation: onCopyTranslation)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("系统翻译").font(.headline)
                Text("系统翻译需要 macOS 14.4 或更新版本。识别文字与复制功能仍可使用。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(16).frame(width: 350)
        }
    }
}

@available(macOS 14.4, *)
private struct LegacyTranslationPreviewView: View {
    let sourceText: String
    let onCopyTranslation: (String) -> Bool
    @State private var isPresented = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("系统翻译").font(.headline)
            Text(sourceText).lineLimit(4).font(.callout).foregroundStyle(.secondary)
            Text("在系统翻译面板中选择语言或复制译文。图片内覆盖翻译需要 macOS 15 或更新版本。")
                .font(.footnote).foregroundStyle(.secondary)
            Button(didCopy ? "已复制译文 · 再次翻译" : "打开系统翻译") { isPresented = true }
                .translationPresentation(isPresented: $isPresented, text: sourceText,
                    replacementAction: { didCopy = onCopyTranslation($0) })
        }
        .padding(16).frame(width: 350)
        .task { isPresented = true }
    }
}

@available(macOS 15.0, *)
private struct NativeTranslationPreviewView: View {
    let sourceText: String
    let onCopyTranslation: (String) -> Bool

    @State private var inputText: String
    @State private var sourceLanguage: Locale.Language?
    @State private var targetLanguage: Locale.Language
    @State private var supportedLanguages: [Locale.Language] = []
    @State private var translatedText: String?
    @State private var translationError: String?
    @State private var isTranslating = true
    @State private var didCopyTranslation = false

    init(sourceText: String, onCopyTranslation: @escaping (String) -> Bool) {
        self.sourceText = sourceText
        self.onCopyTranslation = onCopyTranslation
        let pair = Self.defaultLanguages(for: sourceText)
        _inputText = State(initialValue: sourceText)
        _sourceLanguage = State(initialValue: pair.source)
        _targetLanguage = State(initialValue: pair.target)
    }

    private static func defaultLanguages(
        for text: String
    ) -> (source: Locale.Language?, target: Locale.Language) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage
        let hasChinese = text.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }
        if detected == .simplifiedChinese || detected == .traditionalChinese || hasChinese {
            let source = detected == .traditionalChinese ? "zh-Hant" : "zh-Hans"
            return (Locale.Language(identifier: source), Locale.Language(identifier: "en"))
        }
        if detected == .english || text.unicodeScalars.contains(where: {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }) {
            return (Locale.Language(identifier: "en"), Locale.Language(identifier: "zh-Hans"))
        }
        return (nil, Locale.Language(identifier: "zh-Hans"))
    }

    private func name(for language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    private func changeLanguages(source: Locale.Language?, target: Locale.Language) {
        guard sourceLanguage != source || targetLanguage != target else { return }
        translatedText = nil
        translationError = nil
        isTranslating = true
        didCopyTranslation = false
        sourceLanguage = source
        targetLanguage = target
    }

    private func swapLanguages() {
        guard let source = sourceLanguage ?? Self.defaultLanguages(for: inputText).source,
              source != targetLanguage else { return }
        let oldTarget = targetLanguage
        let reverseInput = translatedText
        changeLanguages(source: oldTarget, target: source)
        if let reverseInput, !reverseInput.isEmpty { inputText = reverseInput }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("翻译")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 8) {
                Menu {
                    Button("自动识别") {
                        changeLanguages(source: nil, target: targetLanguage)
                    }
                    ForEach(supportedLanguages, id: \.minimalIdentifier) { language in
                        Button(name(for: language)) {
                            changeLanguages(source: language, target: targetLanguage)
                        }
                    }
                } label: {
                    Text(sourceLanguage.map(name(for:)) ?? "自动识别")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: swapLanguages) {
                    Image(systemName: "arrow.left.arrow.right")
                        .frame(width: 18, height: 18)
                }
                .help("互换翻译方向")
                .accessibilityLabel("互换原文与目标语言")
                .disabled(sourceLanguage == nil || sourceLanguage == targetLanguage)
                Menu {
                    ForEach(supportedLanguages, id: \.minimalIdentifier) { language in
                        Button(name(for: language)) {
                            changeLanguages(source: sourceLanguage, target: language)
                        }
                        .disabled(language == sourceLanguage)
                    }
                } label: {
                    Text(name(for: targetLanguage))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.bordered)

            Text(inputText)
                .lineLimit(3)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if isTranslating {
                    VStack(spacing: 8) {
                        ScanLoadingOverlay(message: "正在翻译…")
                            .frame(height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("首次使用该语言时，macOS 可能需要下载语言资源。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 75)
                } else if let translationError {
                    Text(translationError)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, minHeight: 75, alignment: .leading)
                } else if let translatedText {
                    ScrollView {
                        Text(translatedText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(210, max(75, CGFloat(translatedText.count / 32 + 1) * 20)))
                }
            }
            .font(.system(size: 13))

            HStack {
                Text("由 macOS 在本机翻译")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(didCopyTranslation ? "已复制" : "复制译文") {
                    guard let translatedText, !translatedText.isEmpty else { return }
                    didCopyTranslation = onCopyTranslation(translatedText)
                }
                .disabled(translatedText?.isEmpty != false)
            }
        }
        .padding(16)
        .frame(width: 430)
        .task {
            supportedLanguages = await LanguageAvailability().supportedLanguages.sorted {
                name(for: $0).localizedStandardCompare(name(for: $1)) == .orderedAscending
            }
        }
        .translationTask(source: sourceLanguage, target: targetLanguage) { session in
            let requestedSource = sourceLanguage
            let requestedTarget = targetLanguage
            let requestedText = inputText
            do {
                let response = try await session.translate(requestedText)
                guard !Task.isCancelled,
                      sourceLanguage == requestedSource,
                      targetLanguage == requestedTarget,
                      inputText == requestedText else { return }
                translatedText = response.targetText
                translationError = nil
                isTranslating = false
            } catch {
                guard !Task.isCancelled,
                      sourceLanguage == requestedSource,
                      targetLanguage == requestedTarget,
                      inputText == requestedText else { return }
                translationError = error.localizedDescription
                isTranslating = false
            }
        }
    }
}
