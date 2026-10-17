import Foundation

struct ExcludedApplication: Codable, Hashable, Identifiable {
    let bundleIdentifier: String
    let name: String

    var id: String { bundleIdentifier }
}

enum RecordingExclusionPolicy {
    static let preferenceKey = "excludedRecordingApplications"

    static func applications(in defaults: UserDefaults) -> [ExcludedApplication] {
        guard let data = defaults.data(forKey: preferenceKey),
              let applications = try? JSONDecoder().decode([ExcludedApplication].self, from: data) else {
            return []
        }
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func configurationIsValid(in defaults: UserDefaults) -> Bool {
        guard let raw = defaults.object(forKey: preferenceKey) else { return true }
        guard let data = raw as? Data else { return false }
        return (try? JSONDecoder().decode([ExcludedApplication].self, from: data)) != nil
    }

    static func save(_ applications: [ExcludedApplication], in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(applications) else { return }
        defaults.set(data, forKey: preferenceKey)
    }

    /// A foreground switch makes attribution during a polling interval uncertain.
    /// If exclusions are configured, skip that interval rather than save a copy
    /// that may have come from an excluded app.
    static func shouldRecord(
        sourceBundleID: String?,
        foregroundChangedSinceLastPoll: Bool,
        excluded: [ExcludedApplication]
    ) -> Bool {
        guard !excluded.isEmpty else { return true }
        guard !foregroundChangedSinceLastPoll,
              let sourceBundleID,
              !sourceBundleID.isEmpty else { return false }
        return !excluded.contains { $0.bundleIdentifier == sourceBundleID }
    }
}
