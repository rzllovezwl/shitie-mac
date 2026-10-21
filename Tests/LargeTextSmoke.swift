import AppKit
import Foundation

private enum LargeTextTestError: Error { case failed(String) }

@main
struct LargeTextSmoke {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoookLargeText-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ClipHoookLargeText-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw LargeTextTestError.failed("无法建立隔离设置")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HistoryRetention.forever.rawValue, forKey: HistoryStoragePolicy.retentionKey)

        let text: String
        if CommandLine.arguments.count > 1 {
            text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        } else {
            text = "{\"items\":[" + Array(repeating: "{\"name\":\"sample\",\"value\":12345}", count: 750_000)
                .joined(separator: ",") + "]}"
        }
        let originalBytes = Data(text.utf8)
        let store = ClipboardHistoryStore(directory: root.appendingPathComponent("History"), defaults: defaults)
        try check(originalBytes.count > 20_000_000 && originalBytes.count <= store.maximumTextBytes,
                  "测试文字没有覆盖超过旧 1 MB 上限的真实文件大小")
        try check(try store.addText(text, sourceAppName: "Xcode", sourceAppBundleID: "com.apple.dt.Xcode"),
                  "大段 JSON 没有保存")
        guard let entry = store.entries.first else { throw LargeTextTestError.failed("历史记录为空") }
        try check(entry.textClassification == .json, "大段 JSON 被标成了普通文本")
        try check(entry.byteCount == originalBytes.count && entry.text == text,
                  "保存时内容发生截断或变化")

        let restored = ClipboardHistoryStore(directory: root.appendingPathComponent("History"), defaults: defaults)
        guard let saved = restored.entries.first else { throw LargeTextTestError.failed("重启后记录丢失") }
        try check(saved.text == text, "重启后内容发生截断")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try check(ClipboardPasteboardWriter.write(saved, from: restored, to: board), "大段文字不能重新复制")
        try check(board.string(forType: .string) == text, "重新复制的内容不完整")
        print("LargeTextSmoke passed (\(originalBytes.count) bytes)")
    }

    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw LargeTextTestError.failed(message) }
    }
}
