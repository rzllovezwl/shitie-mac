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
                  image.size.width > 0, image.size.height > 0 else {
                throw SourceAppIconTestError.notFound(name)
            }
        }

        if FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app") {
            guard await resolver.icon(bundleID: nil, name: "ChatGPT") != nil,
                  await resolver.icon(bundleID: "com.openai.codex", name: "ChatGPT") != nil else {
                throw SourceAppIconTestError.notFound("ChatGPT")
            }
        }
        print("Source app icon smoke test passed")
    }
}
