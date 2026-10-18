import AppKit

private enum SourceAppIconTestError: Error { case notFound(String) }

@main
struct SourceAppIconSmoke {
    @MainActor
    static func main() async throws {
        let resolver = SourceAppIconResolver.shared
        let systemApps: [(String?, String)] = [
            (nil, "系统设置"),
            (nil, "Safari浏览器"),
            ("com.apple.finder", "访达")
        ]
        for (bundleID, name) in systemApps {
            guard let image = await resolver.icon(bundleID: bundleID, name: name),
                  hasVisibleArtwork(image) else {
                throw SourceAppIconTestError.notFound(name)
            }
        }

        if FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app") {
            guard let byName = await resolver.icon(bundleID: nil, name: "ChatGPT"),
                  let byBundle = await resolver.icon(bundleID: "com.openai.codex", name: "ChatGPT"),
                  hasVisibleArtwork(byName), hasVisibleArtwork(byBundle) else {
                throw SourceAppIconTestError.notFound("ChatGPT")
            }
        }
        print("Source app icon smoke test passed")
    }

    private static func hasVisibleArtwork(_ image: NSImage) -> Bool {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()

        var opaqueSamples = 0
        var colors = Set<String>()
        for y in stride(from: 4, through: 60, by: 8) {
            for x in stride(from: 4, through: 60, by: 8) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      pixel.alphaComponent > 0.5 else { continue }
                opaqueSamples += 1
                colors.insert("\(Int(pixel.redComponent * 10)),\(Int(pixel.greenComponent * 10)),\(Int(pixel.blueComponent * 10))")
            }
        }
        return opaqueSamples >= 8 && colors.count >= 3
    }
}
