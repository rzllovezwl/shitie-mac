private enum ClipboardChangeTestError: Error {
    case failed(String)
}

@main
struct ClipboardChangeTrackerSmoke {
    static func main() throws {
        var tracker = ClipboardChangeTracker(initialChangeCount: 10)

        var change = tracker.observe(changeCount: 10)
        try check(!change.shouldNotify && !change.shouldHandle, "启动时不应播放提示音")

        change = tracker.observe(changeCount: 11)
        try check(change.shouldNotify && change.shouldHandle, "外部复制应播放并处理")

        change = tracker.observe(changeCount: 11)
        try check(!change.shouldNotify && change.shouldHandle, "等待剪贴板权限时不应重复播放")

        tracker.markHandled(changeCount: 11)
        change = tracker.observe(changeCount: 11)
        try check(!change.shouldNotify && !change.shouldHandle, "已处理的复制不应再次处理")

        change = tracker.observe(changeCount: 12)
        try check(change.shouldNotify && change.shouldHandle, "相同内容再次复制也应播放")
        tracker.markHandled(changeCount: 12) // 暂停记录时仍消费本次变更
        change = tracker.observe(changeCount: 12)
        try check(!change.shouldNotify && !change.shouldHandle, "恢复记录后不应补录暂停期间的复制")

        tracker.markOwnWrite(changeCount: 13)
        change = tracker.observe(changeCount: 13)
        try check(!change.shouldNotify && !change.shouldHandle, "应用内复制播放后不应再次播放")

        print("Clipboard change tracker smoke test passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ClipboardChangeTestError.failed(message) }
    }
}
