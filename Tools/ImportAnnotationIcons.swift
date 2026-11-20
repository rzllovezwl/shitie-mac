// Convert the supplied SVG source set to vector PDF image assets with AppKit.
// Usage: swift Tools/ImportAnnotationIcons.swift Tools/Assets/AnnotationIcons ClipboardShelf/Assets.xcassets
import AppKit
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let catalog = URL(fileURLWithPath: CommandLine.arguments[2])
// Thicken the paths without resizing their geometry or changing the originals.
let strokeWidthScale = 1.2
func toolbarImage(contentsOf file: URL) throws -> NSImage {
    var svg = try String(contentsOf: file, encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: #"stroke-width\s*=\s*["']([0-9.]+)["']"#)
    let matches = pattern.matches(in: svg, range: NSRange(svg.startIndex..., in: svg))
    for match in matches.reversed() {
        guard let range = Range(match.range(at: 1), in: svg),
              let width = Double(svg[range]) else { continue }
        svg.replaceSubrange(range, with: String(format: "%.5g", width * strokeWidthScale))
    }
    guard let image = NSImage(data: Data(svg.utf8)) else { fatalError("Invalid SVG: \(file.lastPathComponent)") }
    return image
}
let names = ["01-rectangle", "02-circle", "03-arrow", "04-text", "05-zoom-in", "06-mosaic", "07-marker", "08-pen", "09-number", "10-highlight", "11-color", "12-ocr", "13-translate", "14-scroll-capture"]
for name in names {
    // Preserve the supplied originals; refinements live beside them.
    let refinement = source.appendingPathComponent("overrides/" + name + ".svg")
    let file = FileManager.default.fileExists(atPath: refinement.path)
        ? refinement : source.appendingPathComponent(name + ".svg")
    let image = try toolbarImage(contentsOf: file)
    let key = String(name.dropFirst(3))
    let folder = catalog.appendingPathComponent("AnnotationToolbar-\(key).imageset")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 24, height: 24)
    let pdf = CGContext(folder.appendingPathComponent("icon.pdf") as CFURL, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
    image.draw(in: box)
    NSGraphicsContext.restoreGraphicsState()
    pdf.endPDFPage(); pdf.closePDF()
    let json: [String: Any] = ["images": [["filename": "icon.pdf", "idiom": "universal"]], "info": ["author": "xcode", "version": 1], "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"]]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
}
let extras = source.appendingPathComponent("extra")
for file in try FileManager.default.contentsOfDirectory(at: extras, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "svg" }) {
    let image = try toolbarImage(contentsOf: file)
    let folder = catalog.appendingPathComponent("AnnotationToolbar-extra-" + file.deletingPathExtension().lastPathComponent + ".imageset")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 24, height: 24)
    let pdf = CGContext(folder.appendingPathComponent("icon.pdf") as CFURL, mediaBox: &box, nil)!
    pdf.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
    image.draw(in: box)
    NSGraphicsContext.restoreGraphicsState()
    pdf.endPDFPage(); pdf.closePDF()
    let json: [String: Any] = ["images": [["filename": "icon.pdf", "idiom": "universal"]], "info": ["author": "xcode", "version": 1], "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"]]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
}
print("Imported \(names.count) supplied toolbar SVG icons as vector PDFs")
