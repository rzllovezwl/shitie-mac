import Foundation

struct ReleaseRecord: Decodable, Identifiable {
    let version: String
    let build: String
    let date: String
    let title: String
    let changes: [String]

    var id: String { "\(version)-\(build)" }
}

struct ReleaseHistory: Decodable {
    let releases: [ReleaseRecord]

    static func load(from url: URL) throws -> ReleaseHistory {
        let history = try JSONDecoder().decode(ReleaseHistory.self, from: Data(contentsOf: url))
        guard !history.releases.isEmpty else { throw ReleaseHistoryError.empty }
        return history
    }

    static func loadFromBundle(_ bundle: Bundle = .main) throws -> ReleaseHistory {
        guard let url = bundle.url(forResource: "ReleaseHistory", withExtension: "json") else {
            throw ReleaseHistoryError.missingResource
        }
        return try load(from: url)
    }

    func record(version: String, build: String) -> ReleaseRecord? {
        releases.first { $0.version == version && $0.build == build }
    }

    static func currentVersion(in bundle: Bundle = .main) -> (version: String, build: String) {
        (
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        )
    }
}

enum ReleaseHistoryError: Error {
    case missingResource
    case empty
}
