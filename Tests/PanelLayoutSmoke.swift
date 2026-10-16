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

        for placement in PanelPlacement.allCases {
            let sizes = ["compact", "standard", "large"].map {
                PanelLayout.frame(in: screen, placement: placement, heightPreference: $0)
            }
            let dimensions = sizes.map { placement.isVertical ? $0.width : $0.height }
            try check(dimensions[0] < dimensions[1] && dimensions[1] < dimensions[2],
                      "\(placement.title)的三个布局尺寸应依次增大")
            let cardSizes = sizes.map { frame in
                PanelLayout.cardSize(
                    in: CGSize(width: frame.width - 32, height: frame.height - 100),
                    placement: placement
                )
            }
            try check(cardSizes[0].width < cardSizes[1].width && cardSizes[1].width < cardSizes[2].width,
                      "\(placement.title)卡片宽度应随布局自适应")
            try check(cardSizes[0].height < cardSizes[1].height && cardSizes[1].height < cardSizes[2].height,
                      "\(placement.title)卡片高度应随布局自适应")
            for frame in sizes {
                try check(screen.insetBy(dx: 10, dy: 10).contains(frame),
                          "\(placement.title)面板超出屏幕")
                let offscreen = PanelLayout.offscreenFrame(from: frame, placement: placement)
                try check(!screen.intersects(offscreen), "\(placement.title)的弹出动画起点应在屏幕外")
            }
            let frame = sizes[1]
            switch placement {
            case .bottom: try check(frame.minY == 10 && frame.width == 1420, "底部位置错误")
            case .top: try check(frame.maxY == 890 && frame.width == 1420, "顶部位置错误")
            case .left: try check(frame.minX == 10 && frame.height == 880, "左侧位置错误")
            case .right: try check(frame.maxX == 1430 && frame.height == 880, "右侧位置错误")
            }
        }

        for placement in PanelPlacement.allCases {
            let frame = PanelLayout.frame(in: secondScreen, placement: placement, heightPreference: "large")
            try check(secondScreen.insetBy(dx: 10, dy: 10).contains(frame),
                      "\(placement.title)在副屏上超出边界")
        }

        print("Panel layout smoke test passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PanelLayoutTestError.failed(message) }
    }
}
