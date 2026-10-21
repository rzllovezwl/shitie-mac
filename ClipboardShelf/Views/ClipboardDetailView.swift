import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let backingScale: CGFloat
    let imageURL: URL?
    let thumbnailURL: URL?
    let richTextFiles: RichTextSourceFiles
    let fileHasSavedCopy: Bool
    let savedCopyName: String?
    let fileReferenceAvailable: Bool
    let loadFileReferenceImage: () async -> NSImage?
    let makeFilePreviewAccess: () -> FilePreviewAccess?
    let onCopy: () -> Void
    let onRevealOriginalFile: () -> Bool
    let onSaveFileCopy: () -> Void
    let onDelete: () -> Void
    let onImagePreviewAppear: () -> Void
    let onClose: () -> Void
    @State private var revealFailed = false
    @State private var previewMode: TextPreviewMode = .original
    @State private var codeLanguage = "自动"
    @State private var previewResult: TextPreviewResult?
    @State private var selectedFormat = ""
    @State private var fileReferenceImage: NSImage?
    @State private var savedImage: NSImage?
    @State private var imageZoomAction: ImageZoomAction?
    @State private var imageZoomPercentage = 100
    @State private var showsMoreInfo = false

    private var isImageFileReference: Bool {
        guard entry.kind == .fileReference else { return false }
        let type = entry.fileType.flatMap(UTType.init)
            ?? UTType(filenameExtension: URL(fileURLWithPath: entry.fileName ?? "").pathExtension)
        return type?.conforms(to: .image) == true
    }

    private var showsImageZoom: Bool {
        entry.kind == .image || isImageFileReference
    }

    private var previewKey: String {
        "\(entry.id.uuidString)-\(previewMode.rawValue)-\(codeLanguage)"
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

    var body: some View {
        GeometryReader { geometry in
        let expandedHeight = min(142, max(65, geometry.size.height * 0.24))
        let reservedHeight: CGFloat = showsImageZoom
            ? (entry.kind == .fileReference ? 155 : 145)
            : (entry.kind == .fileReference ? 132 : 120)
        let viewportHeight = max(80, geometry.size.height - reservedHeight
                                 - (showsMoreInfo ? expandedHeight : 0))
        let imageViewportSize = CGSize(width: geometry.size.width, height: viewportHeight)
        VStack(alignment: .leading, spacing: showsImageZoom ? 8 : 12) {
            HStack {
                HStack(spacing: 6) {
                    ClipboardContentTypeIcon(entry: entry, size: 16)
                    Text(entry.kind == .unavailableImage ? "未保存图片" :
                         entry.kind == .image ? "图片详情" : entry.kind == .fileReference ? "文件位置引用" :
                         entry.kind == .link ? "链接详情" : "\(entry.textClassification.label)详情")
                }
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onCopy) {
                    LucideLabel("复制", symbol: .copy, iconSize: 13)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(entry.kind == .unavailableImage
                              || (entry.kind == .fileReference && !fileReferenceAvailable))
                if entry.kind == .fileReference {
                    Button(action: onSaveFileCopy) {
                        Text(fileHasSavedCopy ? "更新副本…" : "保存副本…")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(fileHasSavedCopy
                          ? "用原文件的当前内容替换 ClipHoook 保存的副本"
                          : "保存一份文件到 ClipHoook，原文件移动后仍可复制或粘贴")
                }
                Button(action: onDelete) {
                    LucideLabel("删除", symbol: .trash, iconSize: 13)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(action: onClose) {
                    LucideLabel("关闭", symbol: .x, iconSize: 13)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Group {
                if entry.kind == .image,
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
                            makePreviewAccess: makeFilePreviewAccess,
                            onInteractivePreviewAppear: onImagePreviewAppear
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(fileHasSavedCopy
                            ? "已保存本地副本；复制和粘贴时使用副本。"
                            : fileReferenceAvailable
                                ? "仅记录原文件位置，尚未保存文件副本。"
                                : "原文件已移动、删除或无法访问；请选择原文件并保存副本。")
                            .font(.caption)
                            .foregroundStyle(fileReferenceAvailable ? Color.secondary : Color.orange)
                            .multilineTextAlignment(.center)
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
                            if previewMode == .code {
                                Picker("语言", selection: $codeLanguage) {
                                    ForEach(TextPreviewRenderer.codeLanguages, id: \.self) {
                                        Text($0)
                                    }
                                }
                                .frame(width: 115)
                                .accessibilityLabel("代码语言")
                            }
                        }
                        if let previewResult {
                            TextPreviewView(content: previewResult.text) { selectedFormat = $0 }
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
                        Text("\(previewResult?.actualRichText == true ? "原始格式" : "预览样式")：\(selectedFormat)")
                            .lineLimit(1)
                            .help(selectedFormat)
                    }
                    .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: viewportHeight)
            .clipShape(RoundedRectangle(cornerRadius: showsImageZoom ? 10 : 0,
                                        style: .continuous))

            if showsImageZoom {
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
            selectSuggestedPreview()
        }
        .onAppear { selectSuggestedPreview() }
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
