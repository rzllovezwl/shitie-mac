import CoreGraphics
import CoreText
import Foundation

// Generate template PDF assets from the pinned lucide-static icon font. The
// generated PDFs contain paths, so the app does not need to load a font.
let iconNames = [
    "align-left", "arrow-up-left", "circle-check", "circle-help", "clipboard", "clipboard-clock",
    "copy", "braces", "file", "file-code", "file-type", "history", "image", "keyboard", "link-2", "pause", "play",
    "layout-dashboard", "scan-search", "search", "settings-2", "shield-check", "trash-2",
    "triangle-alert", "x"
]

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift GenerateLucideAssets.swift <lucide-static package> <Assets.xcassets>")
}

let packageURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let catalogURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let codepointsURL = packageURL.appendingPathComponent("font/codepoints.json")
let fontURL = packageURL.appendingPathComponent("font/lucide.ttf")
let codepoints = try JSONDecoder().decode([String: UInt16].self, from: Data(contentsOf: codepointsURL))

guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil) else {
    fatalError("Could not register Lucide font at \(fontURL.path)")
}
let font = CTFontCreateWithName("lucide" as CFString, 24, nil)
guard CTFontCopyPostScriptName(font) as String == "lucide" else {
    fatalError("The loaded font is not Lucide")
}

for name in iconNames {
    guard let codepoint = codepoints[name] else {
        fatalError("Lucide icon not found: \(name)")
    }
    var character = UniChar(codepoint)
    var glyph: CGGlyph = 0
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
          let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
        fatalError("Could not extract Lucide icon: \(name)")
    }
    guard CGRect(x: -0.5, y: -0.5, width: 25, height: 25).contains(path.boundingBox) else {
        fatalError("Lucide icon exceeds its 24 pt canvas: \(name)")
    }

    let assetURL = catalogURL.appendingPathComponent("Lucide-\(name).imageset", isDirectory: true)
    try FileManager.default.createDirectory(at: assetURL, withIntermediateDirectories: true)
    let pdfURL = assetURL.appendingPathComponent("icon.pdf")
    var page = CGRect(x: 0, y: 0, width: 24, height: 24)
    guard let context = CGContext(pdfURL as CFURL, mediaBox: &page, nil) else {
        fatalError("Could not create PDF for \(name)")
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.addPath(path)
    context.fillPath()
    context.endPDFPage()
    context.closePDF()

    let contents = """
    {
      "images" : [{ "filename" : "icon.pdf", "idiom" : "universal" }],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : {
        "preserves-vector-representation" : true,
        "template-rendering-intent" : "template"
      }
    }
    """
    try contents.write(to: assetURL.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

print("Generated \(iconNames.count) Lucide vector assets")
