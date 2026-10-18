import CoreGraphics
import Foundation

private enum PasteTargetWindowTestError: Error { case failed(String) }

@main
struct PasteTargetWindowSmoke {
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
        print("Paste target window smoke test passed")
    }
}
