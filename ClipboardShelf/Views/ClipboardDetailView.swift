import AppKit
import SwiftUI

struct ClipboardDetailView: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(entry.kind == .image ? "图片详情" : entry.kind == .link ? "链接详情" : "文本详情", systemImage: entry.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("复制", systemImage: "doc.on.doc", action: onCopy)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("关闭", systemImage: "xmark", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Group {
                if entry.kind == .image,
                   let imageURL,
                   let image = NSImage(contentsOf: imageURL) {
                    ZoomableImageView(image: image, entryID: entry.id)
                        .accessibilityLabel("图片预览，可双指捏合缩放")
                } else {
                    ScrollView {
                        Text(entry.text ?? "")
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("来源：\(entry.sourceAppName ?? "未知")")
                Text("复制时间：\(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                Text("大小：\(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(18)
    }
}
