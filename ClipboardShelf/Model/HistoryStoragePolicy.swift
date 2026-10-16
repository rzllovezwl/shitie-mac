import Foundation

enum HistoryRetention: String, CaseIterable, Identifiable {
    case oneDay = "1d"
    case sevenDays = "7d"
    case fifteenDays = "15d"
    case thirtyDays = "30d"
    case sixMonths = "6m"
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneDay: "1 天"
        case .sevenDays: "7 天"
        case .fifteenDays: "15 天"
        case .thirtyDays: "30 天"
        case .sixMonths: "半年"
        case .forever: "永久"
        }
    }

    func cutoff(before date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .oneDay: calendar.date(byAdding: .day, value: -1, to: date)
        case .sevenDays: calendar.date(byAdding: .day, value: -7, to: date)
        case .fifteenDays: calendar.date(byAdding: .day, value: -15, to: date)
        case .thirtyDays: calendar.date(byAdding: .day, value: -30, to: date)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: date)
        case .forever: nil
        }
    }
}

struct HistoryStoragePolicy {
    static let retentionKey = "historyRetention"
    static let maximumMegabytesKey = "historyMaximumStorageMB"

    let retention: HistoryRetention
    let maximumBytes: Int?

    init(defaults: UserDefaults) {
        retention = HistoryRetention(rawValue: defaults.string(forKey: Self.retentionKey) ?? "7d") ?? .sevenDays
        let maximumMegabytes = defaults.integer(forKey: Self.maximumMegabytesKey)
        let bytesPerMegabyte = 1_024 * 1_024
        maximumBytes = maximumMegabytes > 0
            ? min(maximumMegabytes, Int.max / bytesPerMegabyte) * bytesPerMegabyte
            : nil
    }

    func cutoff(before date: Date, calendar: Calendar = .current) -> Date? {
        retention.cutoff(before: date, calendar: calendar)
    }
}
