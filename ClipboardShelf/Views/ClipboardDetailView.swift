import AppKit
import SwiftUI

struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let thumbnailURL: URL?
    let fileHasSavedCopy: Bool
    let savedCopyName: String?
    let fileReferenceAvailable: Bool
    let onCopy: () -> Void
    let onSaveFileCopy: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LucideLabel(
                    entry.kind == .image ? "图片详情" : entry.kind == .fileReference ? "文件位置引用" :
                        entry.hasRichText ? "富文本详情" : entry.kind == .link ? "链接详情" : "文本详情",
                    symbol: entry.kind.lucideSymbol
                )
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onCopy) {
                    LucideLabel("复制", symbol: .copy, iconSize: 13)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(entry.kind == .fileReference && !fileReferenceAvailable)
                if entry.kind == .fileReference {
                    Button(action: onSaveFileCopy) {
                        Text(fileHasSavedCopy ? "更新副本…" : "保存副本…")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                   let imageURL,
                   let image = NSImage(contentsOf: imageURL) {
                    ZoomableImageView(image: image, entryID: entry.id)
                        .accessibilityLabel("图片预览，可双指捏合缩放")
                } else if entry.kind == .image {
                    Text("图片文件不可用")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entry.kind == .fileReference {
                    VStack(spacing: 8) {
                        FileReferencePreview(entry: entry, thumbnailURL: thumbnailURL)
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
                } else {
                    ScrollView {
                        Text(entry.text ?? "内容文件不可用")
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    SourceAppIconView(
                        bundleID: entry.sourceAppBundleID,
                        name: entry.sourceAppName,
                        size: 13
                    )
                    Text("来源：\(entry.sourceAppName ?? "未知")")
                }
                if entry.kind == .fileReference {
                    Text("原位置：\(entry.filePath ?? "未知")")
                        .lineLimit(2)
                    Text(fileHasSavedCopy ? "保存方式：位置引用 + 本地副本" : "保存方式：仅位置引用")
                    if let savedCopyName {
                        Text("副本文件：\(savedCopyName)")
                            .lineLimit(2)
                    }
                } else if entry.hasRichText {
                    Text("保留格式：复制时优先提供富文本，目标应用不支持时可用纯文本。")
                }
                Text("最近复制：\(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                if let firstCopiedAt = entry.firstCopiedAt {
                    Text("首次复制：\(firstCopiedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                if let copyCount = entry.copyCount {
                    Text("复制次数：\(copyCount)")
                }
                Text("\(entry.kind == .fileReference ? "原文件大小" : "大小")：\(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(18)
    }
}
