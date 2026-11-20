import CoreGraphics
import Foundation

private enum PasteTargetWindowTestError: Error { case failed(String) }

@main
struct PasteTargetWindowSmoke {
    @MainActor
    static func main() throws {
        let owner = kCGWindowOwnerPID as String
        let layer = kCGWindowLayer as String
        let number = kCGWindowNumber as String
        let windows: [[String: Any]] = [
            [owner: 7, layer: 0, number: 101],
            [owner: 42, layer: 3, number: 102],
            [owner: 42, layer: 0, number: 103],
            [owner: 42, layer: 0, number: 104]
        ]
        guard PasteTargetWindow.frontWindowNumber(in: windows, ownedBy: 42) == 103 else {
            throw PasteTargetWindowTestError.failed("应选择原应用最前面的普通窗口")
        }
        guard PasteTargetWindow.frontWindowNumber(in: windows, ownedBy: 99) == nil else {
            throw PasteTargetWindowTestError.failed("不能把其他应用的窗口当作粘贴目标")
        }
        try verifyPinnedImageHandoff()
        print("Paste target window and pinned-image focus handoff smoke tests passed")
    }

    @MainActor
    private static func verifyPinnedImageHandoff() throws {
        let handoff = PasteFocusHandoff()
        let pointer = CGPoint(x: 20, y: 40)
        let movedPointer = CGPoint(x: 21, y: 40)
        guard handoff.allowsPinnedImageKey, handoff.allowsPinnedImageHoverFocus(at: pointer) else {
            throw PasteTargetWindowTestError.failed("未粘贴时，贴图可接收手势焦点")
        }
        let first = handoff.begin()
        let second = handoff.begin()
        handoff.end(first, at: pointer)
        guard !handoff.allowsPinnedImageKey,
              !handoff.allowsPinnedImageHoverFocus(at: movedPointer) else {
            throw PasteTargetWindowTestError.failed("粘贴期间，即使指针移动或旧交接结束，贴图也不能接管焦点")
        }
        handoff.end(second, at: pointer)
        guard handoff.allowsPinnedImageKey,
              !handoff.allowsPinnedImageHoverFocus(at: pointer),
              handoff.allowsPinnedImageHoverFocus(at: movedPointer) else {
            throw PasteTargetWindowTestError.failed("面板收起露出贴图时不能抢焦点；重新移动指针后恢复贴图手势")
        }
        handoff.isSearchInteractionActive = true
        guard !handoff.allowsPinnedImageKey,
              !handoff.allowsPinnedImageHoverFocus(at: pointer) else {
            throw PasteTargetWindowTestError.failed("快速搜索输入时，桌面贴图不能因悬停抢走键盘")
        }
        let searchPaste = handoff.begin()
        handoff.isSearchInteractionActive = false
        guard !handoff.allowsPinnedImageKey else {
            throw PasteTargetWindowTestError.failed("搜索窗关闭后到原应用恢复前，贴图仍不能接管焦点")
        }
        handoff.end(searchPaste, at: pointer)
        guard handoff.allowsPinnedImageKey,
              !handoff.allowsPinnedImageHoverFocus(at: pointer),
              handoff.allowsPinnedImageHoverFocus(at: movedPointer) else {
            throw PasteTargetWindowTestError.failed("搜索粘贴结束后，贴图应在真实移动鼠标时恢复交互")
        }
    }
}
