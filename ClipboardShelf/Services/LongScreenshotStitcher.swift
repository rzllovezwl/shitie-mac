import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stores full-resolution strips, with only the latest two viewports kept
/// for matching and undo. Matching works in source pixels, without scaling Y.
struct LongScreenshotStitcher {
    static let maximumHeight = 16_000
    static let maximumPixels = 40_000_000

    enum Update: Equatable {
        case unchanged, appended, noOverlap, limitReached
    }

    private struct Sample {
        static let columns = 64
        let height: Int
        let pixels: [UInt8]

        init?(_ image: CGImage) {
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: Self.columns * height)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: Self.columns,
                    height: height, bitsPerComponent: 8, bytesPerRow: Self.columns,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: height))
                return true
            }
            guard drawn else { return nil }
            self.height = height
            pixels = bytes
        }

        func rowDifference(_ y: Int, from next: Sample, _ nextY: Int) -> Int {
            var difference = 0
            for x in stride(from: 1, to: Self.columns, by: 3) {
                difference += abs(Int(pixels[y * Self.columns + x])
                                  - Int(next.pixels[nextY * Self.columns + x]))
            }
            return difference
        }

        func difference(from next: Sample, shift: Int, start: Int, end: Int, samples: Int) -> Double {
            guard end > start else { return .infinity }
            let count = min(samples, end - start)
            var total = 0
            for index in 0..<count {
                let y = start + (index * (end - start)) / count
                total += rowDifference(y + shift, from: next, y)
            }
            return Double(total) / Double(count * 21)
        }
    }

    private struct Viewport {
        let image: CGImage
        let sample: Sample

        init?(_ image: CGImage) {
            guard let sample = Sample(image) else { return nil }
            self.image = image
            self.sample = sample
        }
    }

    private struct Undo {
        let viewport: Viewport
        let footer: Int
    }

    private let initial: CGImage
    private var strips: [CGImage] = []
    private var anchor: Viewport
    private var previous: Undo?
    private var withdrawn: Sample?
    private var footer = 0

    init?(_ image: CGImage) {
        guard image.width >= 64, image.height >= 96,
              image.height <= Self.maximumHeight,
              image.width <= Self.maximumPixels / image.height,
              let viewport = Viewport(image) else { return nil }
        initial = image
        anchor = viewport
    }

    var width: Int { initial.width }
    var height: Int { initial.height + strips.reduce(0) { $0 + $1.height } }
    var count: Int { strips.count + 1 }
    var canUndo: Bool { previous != nil }

    mutating func append(_ image: CGImage) -> Update {
        guard image.width == initial.width, image.height == initial.height,
              let next = Viewport(image) else { return .noOverlap }
        let h = initial.height
        let old = anchor.sample
        let new = next.sample
        if new.difference(from: old, shift: 0, start: 0, end: h, samples: 80) < 0.65 {
            withdrawn = nil
            return .unchanged
        }
        if let withdrawn, new.difference(from: withdrawn, shift: 0, start: 0, end: h, samples: 80) < 0.65 {
            return .unchanged
        }
        let minimumShift = 8
        let minimumOverlap = max(42, h / 4)
        let margin = min(h / 8, 160)
        var candidates: [(Int, Double)] = []
        // Compare downscrolled content through the interior of the overlap;
        // pinned headers and footers don't move with the document.
        for shift in minimumShift...(h - minimumOverlap) {
            let overlap = h - shift
            let inset = min(margin, overlap / 5)
            let score = old.difference(from: new, shift: shift, start: inset,
                                       end: overlap - inset, samples: 22)
            if score <= 9 { candidates.append((shift, score)) }
        }
        let ranked = candidates.sorted { $0.1 < $1.1 }.prefix(12).map { shift, _ in
            let overlap = h - shift
            let inset = min(margin, overlap / 5)
            return (shift, old.difference(from: new, shift: shift, start: inset,
                                         end: overlap - inset, samples: 100))
        }.sorted { $0.1 < $1.1 }
        guard let (shift, score) = ranked.first, score < 6 else { return .noOverlap }
        // A repeating list can offer several equally good offsets. Wait for
        // more distinctive content rather than quietly dropping/duplicating rows.
        if ranked.contains(where: { abs($0.0 - shift) > 2 && $0.1 - score < 0.8 }) {
            return .noOverlap
        }
        let detectedFooter = strips.isEmpty ? fixedFooter(old, new, shift: shift) : footer
        let overlapEnd = h - shift - detectedFooter
        let overlapStart = min(margin, overlapEnd / 4)
        guard old.difference(from: new, shift: shift, start: overlapStart,
                             end: overlapEnd, samples: 85) < 10 else { return .noOverlap }
        let newHeight = height + shift
        guard newHeight <= Self.maximumHeight, width <= Self.maximumPixels / newHeight else {
            return .limitReached
        }
        guard let strip = Self.copyStrip(image, y: overlapEnd, height: shift) else { return .noOverlap }
        previous = Undo(viewport: anchor, footer: footer)
        footer = detectedFooter
        anchor = next
        withdrawn = nil
        strips.append(strip)
        return .appended
    }

    mutating func undo() {
        guard let previous else { return }
        withdrawn = anchor.sample
        anchor = previous.viewport
        footer = previous.footer
        strips.removeLast()
        self.previous = nil
    }

    func image() -> CGImage? {
        guard !strips.isEmpty else { return initial }
        guard let head = initial.cropping(to: CGRect(x: 0, y: 0, width: width,
                                                      height: initial.height - footer)),
              let context = Self.bitmap(width: width, height: height, colorSpace: initial.colorSpace)
        else { return nil }
        var offset = height
        func draw(_ strip: CGImage) {
            offset -= strip.height
            context.draw(strip, in: CGRect(x: 0, y: offset, width: width, height: strip.height))
        }
        draw(head)
        for strip in strips { draw(strip) }
        if footer > 0 {
            guard let tail = anchor.image.cropping(to: CGRect(x: 0, y: initial.height - footer,
                                                              width: width, height: footer))
            else { return nil }
            draw(tail)
        }
        return context.makeImage()
    }

    private func fixedFooter(_ old: Sample, _ new: Sample, shift: Int) -> Int {
        // Require a contiguous stable band with visible contrast. A blank
        // document margin alone isn't enough evidence of a fixed footer.
        let h = old.height
        var rows = 0
        var texturedRows = 0
        let searchDepth = min(h / 6, h - shift - 24)
        guard searchDepth >= 8 else { return 0 }
        for y in stride(from: h - 1, through: h - searchDepth, by: -1) {
            guard old.rowDifference(y, from: new, y) <= 32 else { break }
            rows += 1
            if y > 0, old.rowDifference(y, from: old, y - 1) > 85 { texturedRows += 1 }
        }
        return rows >= 8 && texturedRows >= 3 ? rows : 0
    }

    private static func copyStrip(_ image: CGImage, y: Int, height: Int) -> CGImage? {
        guard let crop = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)),
              let context = bitmap(width: image.width, height: height, colorSpace: image.colorSpace)
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: height))
        return context.makeImage()
    }

    private static func bitmap(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

enum LongScreenshotOutput {
    static func trim(_ image: CGImage, top: Int, bottom: Int) -> CGImage? {
        guard top >= 0, bottom >= 0, top < image.height, bottom < image.height - top else { return nil }
        if top == 0 && bottom == 0 { return image }
        return image.cropping(to: CGRect(x: 0, y: top, width: image.width,
                                         height: image.height - top - bottom))
    }

    static func png(_ image: CGImage, fitting maximumBytes: Int? = nil) -> Data? {
        guard let original = encode(image) else { return nil }
        guard let maximumBytes, original.count > maximumBytes else { return original }
        var ratio = min(0.9, sqrt(Double(maximumBytes) / Double(original.count)) * 0.95)
        for _ in 0..<8 {
            let width = max(1, Int(CGFloat(image.width) * ratio))
            let height = max(1, Int(CGFloat(image.height) * ratio))
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let resized = context.makeImage(), let png = encode(resized) else { return nil }
            if png.count <= maximumBytes { return png }
            ratio *= 0.8
        }
        return nil
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
