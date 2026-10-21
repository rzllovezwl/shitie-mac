import AppKit
import SwiftUI

enum LucideSymbol: String, CaseIterable {
    case alignLeft = "align-left"
    case arrowUpLeft = "arrow-up-left"
    case circleCheck = "circle-check"
    case circleHelp = "circle-help"
    case clipboard
    case clipboardClock = "clipboard-clock"
    case copy
    case braces
    case file
    case fileCode = "file-code"
    case fileType = "file-type"
    case history
    case image
    case keyboard
    case layoutDashboard = "layout-dashboard"
    case link = "link-2"
    case pause
    case play
    case scanSearch = "scan-search"
    case search
    case settings = "settings-2"
    case shieldCheck = "shield-check"
    case trash = "trash-2"
    case triangleAlert = "triangle-alert"
    case x

    var assetName: String { "Lucide-\(rawValue)" }
}

extension ClipboardEntry.Kind {
    var lucideSymbol: LucideSymbol {
        switch self {
        case .text: .alignLeft
        case .link: .link
        case .image: .image
        case .unavailableImage: .triangleAlert
        case .fileReference: .file
        case .group: .layoutDashboard
        }
    }
}

struct LucideIcon: View {
    let symbol: LucideSymbol
    let size: CGFloat

    init(_ symbol: LucideSymbol, size: CGFloat = 16) {
        self.symbol = symbol
        self.size = size
    }

    var body: some View {
        Image(symbol.assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A content badge describes the clipboard item, not the source application.
/// Language marks use Devicon or the system Swift symbol. File categories use
/// small monochrome badges so their meaning stays visible without depending
/// on a third-party app's document icon or Launch Services registration.
struct ClipboardContentTypeIcon: View {
    let entry: ClipboardEntry
    let size: CGFloat

    private var fileIconKind: ClipboardFileIconKind {
        ClipboardFileIconKind.classify(fileName: entry.fileName, fileType: entry.fileType)
    }

    var body: some View {
        Group {
            switch entry.kind {
            case .group:
                Image(systemName: "square.stack.3d.up")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            case .image: LucideIcon(.image, size: size)
            case .unavailableImage: LucideIcon(.triangleAlert, size: size)
            case .link: LucideIcon(.link, size: size)
            case .fileReference:
                switch fileIconKind {
                case .image: LucideIcon(.image, size: size)
                case .code: LucideIcon(.fileCode, size: size)
                case .generic: LucideIcon(.file, size: size)
                case .pdf: fileBadge("PDF")
                case .word: fileBadge("W")
                case .spreadsheet: fileBadge("X")
                case .presentation: fileBadge("P")
                case .archive: fileBadge("ZIP")
                case .video:
                    Image(systemName: "film")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                case .audio:
                    Image(systemName: "waveform")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                }
            case .text:
                switch entry.textClassification {
                case .plain: LucideIcon(.alignLeft, size: size)
                case .rich: LucideIcon(.fileType, size: size)
                case .markdown: brand("markdown")
                case .swift:
                    Image(systemName: "swift")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                case .json: LucideIcon(.braces, size: size)
                case .jsonLines: monogram("JL")
                case .yaml: monogram("Y")
                case .xml: monogram("<>")
                case .css: monogram("#")
                case .sql: monogram("DB")
                case .csv: monogram("CSV")
                case .python: brand("python")
                case .javaScript: brand("javascript")
                case .typeScript: monogram("TS")
                case .shell: brand("bash")
                case .html: brand("html5")
                case .objectiveC: monogram("OC")
                case .java: monogram("J")
                case .kotlin: monogram("Kt")
                case .go: monogram("Go")
                case .rust: monogram("Rs")
                case .c: monogram("C")
                case .cpp: monogram("C++")
                case .cSharp: monogram("C#")
                case .php: monogram("PHP")
                case .ruby: monogram("Rb")
                case .dart: monogram("D")
                case .code: LucideIcon(.fileCode, size: size)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func brand(_ name: String) -> some View {
        Image("Devicon-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private func monogram(_ value: String) -> some View {
        Text(value)
            .font(.system(size: size * (value.count > 2 ? 0.37 : 0.5), weight: .bold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.15)
                    .strokeBorder(lineWidth: max(1, size * 0.075))
            }
    }

    private func fileBadge(_ value: String) -> some View {
        Text(value)
            .font(.system(size: size * (value.count > 1 ? 0.4 : 0.62), weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.16)
                    .strokeBorder(lineWidth: max(1, size * 0.08))
            }
    }
}

struct LucideLabel: View {
    let title: String
    let symbol: LucideSymbol
    let iconSize: CGFloat

    init(_ title: String, symbol: LucideSymbol, iconSize: CGFloat = 16) {
        self.title = title
        self.symbol = symbol
        self.iconSize = iconSize
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            LucideIcon(symbol, size: iconSize)
        }
    }
}
