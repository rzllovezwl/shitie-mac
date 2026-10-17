import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileReferencePreview: View {
    let entry: ClipboardEntry
    let thumbnailURL: URL?

    var body: some View {
        VStack(spacing: 8) {
            if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: contentType))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(18)
            }
            Text(entry.fileName ?? "文件")
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let typeName {
                Text(typeName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var fileExtension: String {
        (entry.fileName ?? "").split(separator: ".").last.map(String.init) ?? ""
    }

    private var contentType: UTType {
        entry.fileType.flatMap(UTType.init) ?? UTType(filenameExtension: fileExtension) ?? .data
    }

    private var typeName: String? {
        guard let fileType = entry.fileType else { return nil }
        return UTType(fileType)?.localizedDescription ?? fileType
    }
}
