import SwiftUI

enum LucideSymbol: String, CaseIterable {
    case alignLeft = "align-left"
    case arrowUpLeft = "arrow-up-left"
    case circleCheck = "circle-check"
    case circleHelp = "circle-help"
    case clipboard
    case clipboardClock = "clipboard-clock"
    case copy
    case file
    case history
    case image
    case keyboard
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
        case .fileReference: .file
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
