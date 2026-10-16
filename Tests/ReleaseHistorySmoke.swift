import Foundation

@main
struct ReleaseHistorySmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("请传入构建后的 ClipHoook测试版.app 路径")
        }

        let history = try ReleaseHistory.loadFromBundle(bundle)
        let current = ReleaseHistory.currentVersion(in: bundle)
        guard history.releases.first?.version == current.version,
              history.releases.first?.build == current.build,
              history.record(version: "1.0.0", build: "4") != nil else {
            fatalError("应用包中的当前版本或历史版本记录不正确")
        }

        print("Release history smoke test passed: \(current.version) (\(current.build))")
    }
}
