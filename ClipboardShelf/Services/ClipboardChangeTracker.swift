struct ClipboardChangeTracker {
    private var lastHandledChangeCount: Int
    private var lastNotifiedChangeCount: Int

    init(initialChangeCount: Int) {
        lastHandledChangeCount = initialChangeCount
        lastNotifiedChangeCount = initialChangeCount
    }

    mutating func observe(changeCount: Int) -> (shouldNotify: Bool, shouldHandle: Bool) {
        let shouldNotify = changeCount != lastNotifiedChangeCount
        if shouldNotify {
            lastNotifiedChangeCount = changeCount
        }
        return (shouldNotify, changeCount != lastHandledChangeCount)
    }

    mutating func markHandled(changeCount: Int) {
        lastHandledChangeCount = changeCount
    }

    mutating func markOwnWrite(changeCount: Int) {
        lastHandledChangeCount = changeCount
        lastNotifiedChangeCount = changeCount
    }
}
