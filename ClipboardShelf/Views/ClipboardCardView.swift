import AppKit
import SwiftUI

struct ClipboardCardView: View {
    let entry: ClipboardEntry
    let imageURL: URL?
    let cardSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    private var textScale: CGFloat {
        min(1.25, max(0.9, cardSize.height / 252))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * textScale) {
            HStack(spacing: 6) {
                LucideIcon(entry.kind.lucideSymbol, size: 11 * textScale)
                Text(entry.kind == .image ? "图片" : entry.kind == .link ? "链接" : "文本")
                Spacer(minLength: 4)
                Text(entry.createdAt, style: .relative)
                    .lineLimit(1)
            }
            .font(.system(size: 11 * textScale, weight: .medium))
            .foregroundStyle(.secondary)

            Group {
                if entry.kind == .image,
                   let imageURL,
                   let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entry.kind == .image {
                    Text("图片文件不可用")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(entry.text ?? "内容文件不可用")
                        .font(.system(size: 14 * textScale))
                        .foregroundStyle(.primary)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(entry.sourceAppName ?? "未知来源")
                    .lineLimit(1)
                Spacer()
                LucideIcon(.arrowUpLeft, size: 10 * textScale)
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
        .overlay {
            ImmediateCardInteraction(
                onSelect: onSelect,
                onPaste: onPaste,
                onCopy: onCopy,
                onDelete: onDelete
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title)，单击选中，空格查看或收起详情，左右方向键切换，双击粘贴")
    }
}

private struct ImmediateCardInteraction: NSViewRepresentable {
    let onSelect: () -> Void
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> CardInteractionView {
        CardInteractionView()
    }

    func updateNSView(_ view: CardInteractionView, context: Context) {
        view.onSelect = onSelect
        view.onPaste = onPaste
        view.onCopy = onCopy
        view.onDelete = onDelete
    }
}

private final class CardInteractionView: NSView {
    var onSelect: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onPaste?()
        } else if event.clickCount == 1 {
            onSelect?()
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
