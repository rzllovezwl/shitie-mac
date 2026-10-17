import AppKit
import SwiftUI

struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LucideLabel(
                    entry.kind == .image ? "图片详情" : entry.kind == .link ? "链接详情" : "文本详情",
                    symbol: entry.kind.lucideSymbol
                )
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onCopy) {
                    LucideLabel("复制", symbol: .copy, iconSize: 13)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                Text("来源：\(entry.sourceAppName ?? "未知")")
                Text("最近复制：\(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                if let firstCopiedAt = entry.firstCopiedAt {
                    Text("首次复制：\(firstCopiedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                if let copyCount = entry.copyCount {
                    Text("复制次数：\(copyCount)")
                }
                Text("大小：\(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(18)
    }
}
