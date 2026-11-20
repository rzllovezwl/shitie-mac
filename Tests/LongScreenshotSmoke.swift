import CoreGraphics
import Foundation
import ImageIO

@main
struct LongScreenshotSmoke {
    static func main() throws {
        let original = fixture(offset: 0)
        var stitcher = try require(LongScreenshotStitcher(original))
        try check(stitcher.append(original) == .unchanged, "静止画面不应增加高度")
        try check(stitcher.append(fixture(offset: 16)) == .appended,
                  "短距离滚动应在有固定页脚时正确匹配")
        try check(stitcher.append(fixture(offset: 112)) == .appended, "应匹配重叠区")
        try check(stitcher.count == 3 && stitcher.height == 432, "拼接后尺寸或分段计数错误")
        try check(try pixels(require(stitcher.image())) == pixels(fixture(offset: 0, height: 432)),
                  "像素拼接不应重复固定栏或跳过内容")
        let joined = try require(stitcher.image())
        let trimmed = try require(LongScreenshotOutput.trim(joined, top: 18, bottom: 26))
        let expectedContent = try require(fixture(offset: 0, height: 432)
            .cropping(to: CGRect(x: 0, y: 18, width: 128, height: 388)))
        try check(pixels(trimmed) == pixels(expectedContent), "应从正确一端裁剪")
        try check(LongScreenshotOutput.trim(joined, top: 432, bottom: 0) == nil, "裁剪至少保留一行")
        let png = try require(LongScreenshotOutput.png(trimmed))
        let decoded = try decode(png)
        try check(pixels(decoded) == pixels(trimmed), "原尺寸 PNG 应保留像素")
        let target = png.count / 4
        let smaller = try require(LongScreenshotOutput.png(trimmed, fitting: target))
        let decodedSmall = try decode(smaller)
        try check(smaller.count <= target && decodedSmall.height < trimmed.height &&
                  decodedSmall.width < trimmed.width, "超限时应等比例缩小并符合字节限制")
        try check(stitcher.append(fixture(offset: 500)) == .noOverlap,
                  "滚过头后应拒绝错误拼接")
        try check(stitcher.append(fixture(offset: 12)) == .noOverlap,
                  "往回滚不应当作向下继续拼接")
        stitcher.undo()
        try check(stitcher.height == 336 && stitcher.count == 2 && !stitcher.canUndo,
                  "单步撤回应恢复此前的高度与匹配起点")
        try check(stitcher.append(fixture(offset: 112)) == .unchanged,
                  "撤回后不应立即重加同一画面")
        try check(stitcher.append(fixture(offset: 45)) == .appended,
                  "回滚到中间后可从恢复的起点接着拼")
        try check(try pixels(require(stitcher.image())) == pixels(fixture(offset: 0, height: 365)),
                  "撤回后的拼接不能留下已撤回的内容")

        var repeating = try require(LongScreenshotStitcher(fixture(offset: 0, period: 35)))
        try check(repeating.append(fixture(offset: 38, period: 35)) == .noOverlap,
                  "重复纹样产生歧义时不应选任意接缝")
        var long = try require(LongScreenshotStitcher(fixture(offset: 0)))
        for offset in stride(from: 128, through: 15_616, by: 128) {
            try check(long.append(fixture(offset: offset)) == .appended, "上限内应继续拼接")
        }
        try check(long.append(fixture(offset: 15_744)) == .limitReached && long.height == 15_936,
                  "达到长度限制时应保留已拼好的长图")
        print("长截图检查通过：像素级接缝、固定栏去重、滚动方向、失败恢复、撤回、歧义与长度上限")
    }

    private static func fixture(offset: Int, height: Int = 320, period: Int? = nil) -> CGImage {
        let context = bitmap(width: 128, height: height)
        for y in 0..<height {
            let row: Int
            if y < 18 {
                row = y + 50_000
            } else if y >= height - 26 {
                row = y - height + 60_000
            } else {
                row = period.map { (y + offset) % $0 } ?? y + offset
            }
            for x in stride(from: 0, to: 128, by: 8) {
                var value = UInt32(truncatingIfNeeded: row * 128 + x)
                value ^= value >> 16
                value &*= 0x7feb352d
                value ^= value >> 15
                value &*= 0x846ca68b
                value ^= value >> 16
                let color = CGFloat(value & 0xff) / 255
                context.setFillColor(red: color, green: color, blue: color, alpha: 1)
                context.fill(CGRect(x: x, y: height - y - 1, width: 8, height: 1))
            }
        }
        return context.makeImage()!
    }

    private static func decode(_ data: Data) throws -> CGImage {
        let source = try require(CGImageSourceCreateWithData(data as CFData, nil))
        return try require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func pixels(_ image: CGImage) -> Data {
        let context = bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: context.bytesPerRow * image.height)
    }

    private static func bitmap(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "未能生成测试图片") }
        return value
    }
}
