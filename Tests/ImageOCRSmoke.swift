import AppKit
import Foundation

@main
struct ImageOCRSmoke {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipHoook-OCR-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let image = NSImage(size: NSSize(width: 900, height: 5_000))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 5_000).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 66, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        ("TOP 12345" as NSString).draw(at: NSPoint(x: 80, y: 4_700), withAttributes: attributes)
        ("中文识别 你好" as NSString).draw(at: NSPoint(x: 80, y: 2_450), withAttributes: attributes)
        ("BOTTOM 67890" as NSString).draw(at: NSPoint(x: 80, y: 180), withAttributes: attributes)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("无法创建测试图片")
        }
        try png.write(to: url)
        let text = try await ImageOCRService.recognize(at: url)
        precondition(text.contains("12345") && text.contains("67890"),
                     "长图分块识别应保留顶部和底部文字，实际结果：\(text)")
        precondition(text.range(of: "12345")!.lowerBound < text.range(of: "67890")!.lowerBound,
                     "识别结果应按图片从上到下排列，实际结果：\(text)")
        precondition(text.contains("你好"), "应能识别图片中的中文，实际结果：\(text)")

        guard let inMemoryImage = bitmap.cgImage else {
            preconditionFailure("无法取得未保存截图的像素")
        }
        let inMemoryText = try await ImageOCRService.recognize(inMemoryImage)
        precondition(inMemoryText.contains("12345") && inMemoryText.contains("67890")
                     && inMemoryText.contains("你好"),
                     "未保存截图也应直接识别完整文字，实际结果：\(inMemoryText)")
        let positionedLines = try await ImageOCRService.recognizeLines(inMemoryImage)
        guard let top = positionedLines.first(where: { $0.text.contains("12345") }),
              let bottom = positionedLines.first(where: { $0.text.contains("67890") }) else {
            preconditionFailure("截图翻译需要保留每行识别文字的位置")
        }
        precondition(top.rect.minY < bottom.rect.minY &&
                     positionedLines.allSatisfy({ $0.rect.minX >= 0 && $0.rect.minY >= 0 &&
                         $0.rect.maxX <= CGFloat(inMemoryImage.width) + 1 &&
                         $0.rect.maxY <= CGFloat(inMemoryImage.height) + 1 }),
                     "译文覆盖坐标应以图片左上角为原点，且不能超出图片范围")

        let timeoutStarted = Date()
        do {
            _ = try await ImageOCRService.recognize(at: url, timeout: .milliseconds(1))
            preconditionFailure("超时后应结束等待")
        } catch ImageOCRError.timedOut {
            precondition(Date().timeIntervalSince(timeoutStarted) < 5,
                         "超时提示不应等待底层识别任务结束")
        }
        print("Image OCR smoke test passed")
    }
}
