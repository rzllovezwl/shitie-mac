import AppKit

enum PinnedImageLayout {
    static func frame(imageSize: NSSize, visibleFrame: NSRect, cursor: NSPoint) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 16, dy: 16)
        let width = imageSize.width.isFinite && imageSize.width > 0 ? imageSize.width : 400
        let height = imageSize.height.isFinite && imageSize.height > 0 ? imageSize.height : 300
        let maximumImageWidth = min(620, bounds.width * 0.65)
        let maximumImageHeight = min(460, bounds.height * 0.65)
        let scale = min(1, maximumImageWidth / width, maximumImageHeight / height)
        let windowWidth = min(bounds.width, max(240, width * scale + 16))
        let windowHeight = min(bounds.height, max(170, height * scale + 16))
        let x = min(max(cursor.x + 20, bounds.minX), bounds.maxX - windowWidth)
        let y = min(max(cursor.y - windowHeight / 2, bounds.minY), bounds.maxY - windowHeight)
        return NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
    }
}
