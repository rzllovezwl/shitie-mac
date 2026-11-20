import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Mechanically export the approved raster master to the existing macOS icon
// catalog sizes. Do not redraw, crop, add backgrounds or alter the artwork.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift ExportAppIcon.swift <master.png> <AppIcon.appiconset>")
}
let master = URL(fileURLWithPath: CommandLine.arguments[1])
let catalog = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(master as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height, image.width >= 1024 else {
    fatalError("App icon master must be square and at least 1024 px")
}
let contents = try JSONSerialization.jsonObject(with:
    Data(contentsOf: catalog.appendingPathComponent("Contents.json"))) as! [String: Any]
let entries = contents["images"] as! [[String: String]]
for entry in entries {
    guard entry["idiom"] == "mac", let name = entry["filename"],
          URL(fileURLWithPath: name).lastPathComponent == name, name.hasSuffix(".png"),
          let points = entry["size"]?.split(separator: "x").first.flatMap({ Int($0) }),
          let scale = entry["scale"].flatMap({ Int($0.dropLast()) }) else {
        fatalError("Invalid macOS icon catalog entry")
    }
    let pixels = points * scale
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create icon bitmap")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let data = NSMutableData()
    guard let result = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not encode icon")
    }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
    try (data as Data).write(to: catalog.appendingPathComponent(name), options: .atomic)
    print("\(name): \(pixels) x \(pixels), alpha preserved")
}
