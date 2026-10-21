import Foundation

private enum TrackerTestError: Error { case failed(String) }

@main
struct ClipboardChangeTrackerSmoke {
    static func main() throws {
        var tracker = ClipboardChangeTracker(initialChangeCount: 10)
        let start = Date(timeIntervalSince1970: 100)
        let first = tracker.observe(changeCount: 11, at: start)
        try check(first.shouldNotify && first.shouldHandle, "新复制未进入处理流程")

        try check(tracker.deferHandling(changeCount: 11, at: start), "临时不可读的复制未安排重试")
        let tooEarly = tracker.observe(changeCount: 11, at: start.addingTimeInterval(0.2))
        try check(!tooEarly.shouldNotify && !tooEarly.shouldHandle, "读取失败后立即重复处理")
        let ready = tracker.observe(changeCount: 11, at: start.addingTimeInterval(0.5))
        try check(!ready.shouldNotify && ready.shouldHandle, "同一复制未按时重试")

        tracker.markHandled(changeCount: 11)
        try check(!tracker.observe(changeCount: 11, at: start.addingTimeInterval(1)).shouldHandle,
                  "成功记录后仍重复保存")

        try check(tracker.deferHandling(changeCount: 12, at: start), "下一次复制未安排重试")
        let replacement = tracker.observe(changeCount: 13, at: start.addingTimeInterval(0.1))
        try check(replacement.shouldNotify && replacement.shouldHandle,
                  "新的复制被上一条的重试等待挡住")

        for attempt in 0..<8 {
            let willRetry = tracker.deferHandling(
                changeCount: 13, at: start.addingTimeInterval(Double(attempt) * 10)
            )
            try check(willRetry == (attempt < 7), "重试次数没有按上限结束")
        }
        try check(!tracker.observe(changeCount: 13, at: start.addingTimeInterval(100)).shouldHandle,
                  "永久无法读取的内容持续重试")
        print("ClipboardChangeTrackerSmoke passed")
    }

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw TrackerTestError.failed(message) }
    }
}
