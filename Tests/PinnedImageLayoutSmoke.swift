import AppKit

@main
struct PinnedImageLayoutSmoke {
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let inset = screen.insetBy(dx: 16, dy: 16)
        for (image, cursor) in [
            (NSSize(width: 4000, height: 2200), NSPoint(x: 1900, y: 1000)),
            (NSSize(width: 600, height: 1600), NSPoint(x: 20, y: 20)),
            (NSSize(width: 20, height: 20), NSPoint(x: 960, y: 540)),
            (NSSize(width: 0, height: 0), NSPoint(x: 960, y: 540))
        ] {
            let frame = PinnedImageLayout.frame(imageSize: image, visibleFrame: screen, cursor: cursor)
            precondition(frame.width >= 240 && frame.height >= 170)
            precondition(inset.contains(frame), "固定图片窗口不能超出当前屏幕")
        }

        let image = NSSize(width: 1600, height: 900)
        let first = PinnedImageLayout.frame(
            imageSize: image, visibleFrame: screen, cursor: NSPoint(x: 800, y: 500)
        )
        let otherScreen = NSRect(x: 1920, y: 0, width: 1440, height: 900)
        let second = PinnedImageLayout.frame(
            imageSize: image, visibleFrame: otherScreen, cursor: NSPoint(x: 2500, y: 450)
        )
        precondition(first.minX < 1920 && second.minX >= otherScreen.minX)
        print("Pinned image layout smoke test passed")
    }
}
