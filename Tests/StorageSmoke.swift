import Foundation

private enum StorageTestError: Error {
    case failed(String)
}

@main
struct StorageSmoke {
    @MainActor
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardShelfStorageTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suiteName = "ClipboardShelfStorageTest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw StorageTestError.failed("无法建立独立测试设置")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = { now }

        let store = ClipboardHistoryStore(directory: folder, defaults: defaults, now: clock)
        guard try store.addText("第一条", sourceAppName: "测试应用") else {
            throw StorageTestError.failed("添加文字失败")
        }
        let originalID = store.entries[0].id
        _ = try store.addText("第二条", sourceAppName: "测试应用")
        _ = try store.addText("第一条", sourceAppName: "另一个应用")
        guard store.entries.count == 2, store.entries[0].id == originalID else {
            throw StorageTestError.failed("去重或排序失败")
        }

        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        _ = try store.addImage(image, type: "public.png", sourceAppName: "测试应用")
        guard let imageURL = store.imageURL(for: store.entries[0]),
              (try? Data(contentsOf: imageURL)) == image else {
            throw StorageTestError.failed("图片保存失败")
        }

        let reloaded = ClipboardHistoryStore(directory: folder, defaults: defaults, now: clock)
        guard reloaded.entries.count == 3, reloaded.entries[1].id == originalID else {
            throw StorageTestError.failed("重启后历史恢复失败")
        }
        try reloaded.clear()
        guard reloaded.entries.isEmpty, !FileManager.default.fileExists(atPath: imageURL.path) else {
            throw StorageTestError.failed("清空历史未删除图片")
        }

        _ = try reloaded.addText("默认七天", sourceAppName: nil)
        now.addTimeInterval(8 * 24 * 60 * 60)
        let expiredOnLaunch = ClipboardHistoryStore(directory: folder, defaults: defaults, now: clock)
        guard expiredOnLaunch.entries.isEmpty else {
            throw StorageTestError.failed("启动时没有删除超过默认 7 天的记录")
        }

        defaults.set(HistoryRetention.forever.rawValue, forKey: HistoryStoragePolicy.retentionKey)
        for index in 0..<120 {
            _ = try expiredOnLaunch.addText("不限制数量 \(index)", sourceAppName: nil)
        }
        guard expiredOnLaunch.entries.count == 120 else {
            throw StorageTestError.failed("永久保存时仍存在旧的 100 条数量限制")
        }
        now.addTimeInterval(2 * 24 * 60 * 60)
        defaults.set(HistoryRetention.oneDay.rawValue, forKey: HistoryStoragePolicy.retentionKey)
        guard try expiredOnLaunch.applyStoragePolicy(), expiredOnLaunch.entries.isEmpty else {
            throw StorageTestError.failed("修改保存时间后没有立即清理过期记录")
        }

        let imageFolder = folder.appendingPathComponent("storage-limit", isDirectory: true)
        defaults.set(HistoryRetention.forever.rawValue, forKey: HistoryStoragePolicy.retentionKey)
        defaults.set(0, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        let limited = ClipboardHistoryStore(directory: imageFolder, defaults: defaults, now: clock)
        _ = try limited.addImage(Data(repeating: 0x89, count: 600_000), type: "public.png", sourceAppName: nil)
        guard let oldestImageURL = limited.entries.first.flatMap({ limited.imageURL(for: $0) }) else {
            throw StorageTestError.failed("首张图片没有保存")
        }
        now.addTimeInterval(1)
        _ = try limited.addImage(Data(repeating: 0x50, count: 600_000), type: "public.png", sourceAppName: nil)
        guard limited.entries.count == 2 else {
            throw StorageTestError.failed("默认无存储上限时错误删除了记录")
        }
        defaults.set(1, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        guard try limited.applyStoragePolicy() else {
            throw StorageTestError.failed("设置存储上限后没有立即清理")
        }
        guard limited.entries.count == 1,
              !FileManager.default.fileExists(atPath: oldestImageURL.path),
              let newestImageURL = limited.entries.first.flatMap({ limited.imageURL(for: $0) }),
              FileManager.default.fileExists(atPath: newestImageURL.path) else {
            throw StorageTestError.failed("超过存储上限时未从最早记录开始删除图片")
        }

        defaults.set(0, forKey: HistoryStoragePolicy.maximumMegabytesKey)
        _ = try limited.addText("取消存储上限", sourceAppName: nil)
        guard limited.entries.count == 2 else {
            throw StorageTestError.failed("取消存储上限后仍删除了记录")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let augustEnd = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31))!
        let cutoff = HistoryRetention.sixMonths.cutoff(before: augustEnd, calendar: calendar)
        try check(cutoff == calendar.date(from: DateComponents(year: 2026, month: 2, day: 28)),
                  "半年应按日历月计算")
        print("Storage smoke test passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw StorageTestError.failed(message) }
    }
}
