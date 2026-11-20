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
              history.releases.first?.build == current.build else {
            fatalError("应用包中的当前版本记录不正确")
        }

        let recordedBuilds = Set(history.releases.filter { $0.version == "1.0.0" }.map(\.build))
        let missing = (1...272).map { String($0) }.filter { !recordedBuilds.contains($0) }
        guard missing.isEmpty else {
            fatalError("应用包缺少已核实的历史版本：\(missing.joined(separator: "、"))")
        }

        let rows = history.releases.flatMap(\.changeRows)
        guard Set(rows.map(\.id)).count == rows.count else {
            fatalError("不同构建的更新条目使用了相同的列表标识")
        }
        for (build, detail) in [
            ("46", "分类导航"), ("47", "独立滚动"), ("48", "毛玻璃"),
            ("226", "描边"), ("227", "重影"), ("228", "拼音"), ("229", "八色")
        ] {
            guard history.record(version: "1.0.0", build: build)?
                .changeRows.contains(where: { $0.text.contains(detail) }) == true else {
                fatalError("构建 \(build) 的版本正文缺少“\(detail)”")
            }
        }

        print("Release history smoke test passed: \(current.version) (\(current.build)), \(history.releases.count) builds, \(rows.count) unique change rows")
    }
}
