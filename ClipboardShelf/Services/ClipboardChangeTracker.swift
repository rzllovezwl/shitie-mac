import Foundation

struct ClipboardChangeTracker {
    private var lastHandledChangeCount: Int
    private var lastNotifiedChangeCount: Int
    private var deferredChangeCount: Int?
    private var failedAttempts = 0
    private var nextRetryAt = Date.distantPast
    private static let retryDelays: [TimeInterval] = [0.4, 0.8, 1.2, 2, 3, 5, 8]

    init(initialChangeCount: Int) {
        lastHandledChangeCount = initialChangeCount
        lastNotifiedChangeCount = initialChangeCount
    }

    mutating func observe(changeCount: Int, at now: Date = .now) -> (shouldNotify: Bool, shouldHandle: Bool) {
        let shouldNotify = changeCount != lastNotifiedChangeCount
        if shouldNotify {
            lastNotifiedChangeCount = changeCount
        }
        let retryIsDue = deferredChangeCount != changeCount || now >= nextRetryAt
        return (shouldNotify, changeCount != lastHandledChangeCount && retryIsDue)
    }

    mutating func markHandled(changeCount: Int) {
        lastHandledChangeCount = changeCount
        deferredChangeCount = nil
        failedAttempts = 0
        nextRetryAt = .distantPast
    }

    /// Pasteboard providers may publish a URL before its image becomes readable.
    /// Revisit that same change count with bounded backoff instead of dropping it.
    mutating func deferHandling(changeCount: Int, at now: Date = .now) -> Bool {
        failedAttempts = deferredChangeCount == changeCount ? failedAttempts + 1 : 1
        guard failedAttempts <= Self.retryDelays.count else {
            markHandled(changeCount: changeCount)
            return false
        }
        deferredChangeCount = changeCount
        nextRetryAt = now.addingTimeInterval(Self.retryDelays[failedAttempts - 1])
        return true
    }

    mutating func markOwnWrite(changeCount: Int) {
        markHandled(changeCount: changeCount)
        lastNotifiedChangeCount = changeCount
    }
}
