import CoreGraphics

private enum PanelLayoutTestError: Error {
    case failed(String)
}

@main
struct PanelLayoutSmoke {
    static func main() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let compact = PanelLayout.frame(in: screen, heightPreference: "compact")
        let standard = PanelLayout.frame(in: screen, heightPreference: "standard")
        let large = PanelLayout.frame(in: screen, heightPreference: "large")

        try check(compact.minX == 10 && compact.minY == 10 && compact.width == 1420,
                  "面板应保持左右及底部 10 pt 边距")
        try check(compact.height == 300, "紧凑高度不正确")
        try check(abs(standard.height - 342) < 0.01, "标准高度不正确")
        try check(abs(large.height - 468) < 0.01, "宽敞高度不正确")
        try check(compact.maxX == standard.maxX && standard.minY == large.minY,
                  "切换高度时不应移动面板底边或侧边")

        let secondScreen = CGRect(x: 1920, y: -100, width: 1280, height: 720)
        let moved = PanelLayout.frame(in: secondScreen, heightPreference: "large")
        try check(moved.minX == 1930 && moved.minY == -90 && moved.width == 1260,
                  "副屏坐标不正确")

        let shortScreen = CGRect(x: 0, y: 0, width: 800, height: 280)
        let limited = PanelLayout.frame(in: shortScreen, heightPreference: "large")
        try check(limited.height == 260, "面板不应超出较矮屏幕")

        print("Panel layout smoke test passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PanelLayoutTestError.failed(message) }
    }
}
