import AppKit
import SwiftUI

struct TextPreviewView: NSViewRepresentable {
    let content: NSAttributedString
    let interactive: Bool
    let onTextSelectionChange: (String) -> Void
    let onSelectionChange: (String) -> Void

    init(
        content: NSAttributedString,
        interactive: Bool = true,
        onTextSelectionChange: @escaping (String) -> Void = { _ in },
        onSelectionChange: @escaping (String) -> Void = { _ in }
    ) {
        self.content = content
        self.interactive = interactive
        self.onTextSelectionChange = onTextSelectionChange
        self.onSelectionChange = onSelectionChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextSelectionChange: onTextSelectionChange,
                    onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = interactive
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = interactive
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainerInset = interactive
            ? NSSize(width: 12, height: 10)
            : NSSize(width: 7, height: 5)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onTextSelectionChange = onTextSelectionChange
        context.coordinator.onSelectionChange = onSelectionChange
        guard let textView = context.coordinator.textView,
              context.coordinator.lastContent !== content else { return }
        context.coordinator.lastContent = content
        textView.textStorage?.setAttributedString(content)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        context.coordinator.reportSelection()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextSelectionChange: (String) -> Void
        var onSelectionChange: (String) -> Void
        weak var textView: NSTextView?
        var lastContent: NSAttributedString?

        init(onTextSelectionChange: @escaping (String) -> Void,
             onSelectionChange: @escaping (String) -> Void) {
            self.onTextSelectionChange = onTextSelectionChange
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) { reportSelection() }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            true // Preview links never navigate or run code.
        }

        func reportSelection() {
            guard let textView, let content = textView.textStorage, content.length > 0 else {
                DispatchQueue.main.async {
                    self.onTextSelectionChange("")
                    self.onSelectionChange("无文字格式信息")
                }
                return
            }
            let range = textView.selectedRange()
            let selectedText = range.location != NSNotFound && range.length > 0 &&
                NSMaxRange(range) <= content.length
                ? (content.string as NSString).substring(with: range) : ""
            let index = min(range.location, content.length - 1)
            let attributes = content.attributes(at: index, effectiveRange: nil)
            let info = Self.describe(attributes)
            DispatchQueue.main.async {
                self.onTextSelectionChange(selectedText)
                self.onSelectionChange(info)
            }
        }

        static func describe(_ attributes: [NSAttributedString.Key: Any]) -> String {
            guard let font = attributes[.font] as? NSFont else { return "此处无字体信息" }
            var components = [font.displayName ?? font.fontName, String(format: "%.0f pt", font.pointSize)]
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { components.append("加粗") }
            if traits.contains(.italic) { components.append("斜体") }
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 { components.append("下划线") }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { components.append("删除线") }
            if let foreground = attributes[.foregroundColor] as? NSColor,
               let hex = colorHex(foreground) { components.append("文字 \(hex)") }
            if let background = attributes[.backgroundColor] as? NSColor,
               let hex = colorHex(background) { components.append("背景 \(hex)") }
            return components.joined(separator: " · ")
        }

        private static func colorHex(_ color: NSColor) -> String? {
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
            return String(format: "#%02X%02X%02X",
                          Int((rgb.redComponent * 255).rounded()),
                          Int((rgb.greenComponent * 255).rounded()),
                          Int((rgb.blueComponent * 255).rounded()))
        }
    }
}
