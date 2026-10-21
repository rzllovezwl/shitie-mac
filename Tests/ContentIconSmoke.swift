import AppKit

@main
struct ContentIconSmoke {
    static func main() throws {
        let examples: [(String, ClipboardFileIconKind)] = [
            ("image.png", .image),
            ("report.pdf", .pdf),
            ("draft.docx", .word),
            ("budget.xlsx", .spreadsheet),
            ("slides.pptx", .presentation),
            ("archive.zip", .archive),
            ("clip.mov", .video),
            ("music.mp3", .audio),
            ("main.swift", .code),
            ("unknown.bin", .generic)
        ]
        for (name, expected) in examples {
            let actual = ClipboardFileIconKind.classify(fileName: name, fileType: nil)
            guard actual == expected else {
                throw Failure.incorrectKind(file: name, actual: actual)
            }
        }
        guard NSImage(systemSymbolName: "swift", accessibilityDescription: nil) != nil else {
            throw Failure.missingSwiftSymbol
        }
        print("ContentIconSmoke passed")
    }

    private enum Failure: Error {
        case incorrectKind(file: String, actual: ClipboardFileIconKind)
        case missingSwiftSymbol
    }
}
