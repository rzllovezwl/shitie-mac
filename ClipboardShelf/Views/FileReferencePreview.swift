import AppKit
import AVKit
import QuickLookUI
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
        }
        .accessibilityElement(children: .combine)
    }

    private var fileExtension: String {
        (entry.fileName ?? "").split(separator: ".").last.map(String.init) ?? ""
    }

    private var contentType: UTType {
        entry.fileType.flatMap(UTType.init) ?? UTType(filenameExtension: fileExtension) ?? .data
    }

}

/// Only the opened detail uses Quick Look; history cards keep their thumbnails.
struct FileQuickLookPreview: View {
    let entry: ClipboardEntry
    let thumbnailURL: URL?
    let makePreviewAccess: () -> FilePreviewAccess?
    let onInteractivePreviewAppear: () -> Void
    @State private var previewAccess: FilePreviewAccess?

    private var isPlayableMedia: Bool {
        let fileExtension = URL(fileURLWithPath: entry.fileName ?? "").pathExtension
        let type = entry.fileType.flatMap(UTType.init) ?? UTType(filenameExtension: fileExtension)
        return type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true
    }

    var body: some View {
        Group {
            if let previewAccess {
                if isPlayableMedia {
                    FileMediaPreview(access: previewAccess)
                        .id(previewAccess.url)
                        .onAppear(perform: onInteractivePreviewAppear)
                } else {
                    EmbeddedSystemFilePreview(access: previewAccess)
                        .id(previewAccess.url)
                        .onAppear(perform: onInteractivePreviewAppear)
                }
            } else {
                FileReferencePreview(entry: entry, thumbnailURL: thumbnailURL)
            }
        }
        .task(id: "\(entry.id.uuidString)-\(entry.fileCopyName ?? "")") {
            previewAccess = makePreviewAccess()
        }
    }
}

/// AVKit provides working transport controls for files that Quick Look may
/// display as a poster frame inside our floating panel.
private struct FileMediaPreview: View {
    let access: FilePreviewAccess
    @State private var player: AVPlayer

    init(access: FilePreviewAccess) {
        self.access = access
        _player = State(initialValue: AVPlayer(url: access.url))
    }

    var body: some View {
        VStack(spacing: 7) {
            EmbeddedMediaPlayerView(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Button {
                    player.play()
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                Button {
                    player.pause()
                } label: {
                    Label("暂停", systemImage: "pause.fill")
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onDisappear { player.pause() }
    }
}

private struct EmbeddedMediaPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: .zero)
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Quick Look supplies the macOS document renderer for PDFs, Office files,
/// text, Markdown, and installed preview extensions.
private struct EmbeddedSystemFilePreview: NSViewRepresentable {
    let access: FilePreviewAccess

    final class Coordinator {
        var access: FilePreviewAccess

        init(access: FilePreviewAccess) {
            self.access = access
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(access: access)
    }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        // The detail panel is reused. Close when SwiftUI removes this view,
        // rather than waiting for the NSPanel itself to close.
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = access.url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.access.url != access.url else { return }
        view.previewItem = access.url as NSURL
        context.coordinator.access = access
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

struct SavedFileCopyBadge: View {
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
            Text("已存副本")
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.13), in: Capsule())
        .fixedSize()
        .accessibilityLabel("已保存本地文件副本")
    }
}
