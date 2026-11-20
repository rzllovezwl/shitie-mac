import CoreGraphics

@main
struct PanelCardDragSmoke {
    enum Failure: Error { case failed(String) }
    static func main() throws {
        let draggingLevel = Int(CGWindowLevelForKey(.draggingWindow))
        let shelfLevel = PanelLayout.shelfWindowLevel
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        try check(shelfLevel < draggingLevel && shelfLevel > dockLevel,
                  "面板的固定层级必须低于拖动缩略图，并保持在 Dock 上方")
        for level in [shelfLevel, shelfLevel + 2, shelfLevel + 3, Int(CGWindowLevelForKey(.screenSaverWindow))] {
            let background = PanelLayout.screenshotBackgroundWindowLevel(for: level)
            try check(background > dockLevel && background < shelfLevel,
                      "截图背景面板必须在 Dock 上方、标注和选择层下方，不能因截图露出 Dock")
        }
        for level in [0, 3, dockLevel - 1] {
            try check(PanelLayout.screenshotBackgroundWindowLevel(for: level) == level,
                      "原本位于较低层级的窗口不能因截图被强制抬高")
        }
        for frame in [CGRect(x: 20, y: 20, width: 900, height: 340),
                      CGRect(x: -1200, y: 140, width: 320, height: 820),
                      CGRect(x: 100, y: -900, width: 1000, height: 340)] {
            var drag = PanelCardDragState()
            drag.begin(in: frame)
            for point in [CGPoint(x: frame.midX, y: frame.midY),
                          CGPoint(x: frame.minX + 1, y: frame.maxY - 1),
                          CGPoint(x: frame.maxX - 1, y: frame.minY + 1)] {
                try check(!drag.moved(to: point) && !drag.hasLeftPanel, "面板内拖动不应收起")
            }
            try check(!drag.shouldHideAfterDrop(succeeded: true), "拖入收藏成功应保持面板")
            try check(drag.moved(to: CGPoint(x: frame.maxX + 1, y: frame.midY)), "越过面板边界应收起")
            try check(!drag.moved(to: CGPoint(x: frame.maxX + 50, y: frame.midY)), "外部拖动只触发一次收起")
            try check(drag.shouldHideAfterDrop(succeeded: true), "外部投放成功应保持收起")
            try check(!drag.shouldHideAfterDrop(succeeded: false), "Esc 或投放失败应恢复面板")
            drag.reset()
            try check(!drag.isActive && !drag.hasLeftPanel, "结束拖动应清理状态")
        }
        print("Panel card drag smoke passed: screenshot Dock ordering, in-panel, favorites, boundary crossing, external drop and cancel")
    }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.failed(message) }
    }
}
