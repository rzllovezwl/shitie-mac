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

        let store = ClipboardHistoryStore(directory: folder)
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

        let reloaded = ClipboardHistoryStore(directory: folder)
        guard reloaded.entries.count == 3, reloaded.entries[1].id == originalID else {
            throw StorageTestError.failed("重启后历史恢复失败")
        }
        try reloaded.clear()
        guard reloaded.entries.isEmpty, !FileManager.default.fileExists(atPath: imageURL.path) else {
            throw StorageTestError.failed("清空历史未删除图片")
        }
        print("Storage smoke test passed")
    }
}
