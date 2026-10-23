import AppKit
import ImageIO
import SwiftUI

private struct PinnedImageContent: View {
    let image: NSImage
    let allSpaces: Bool
    let onCopy: () -> Void
    let onToggleAllSpaces: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .accessibilityLabel("钉在桌面的图片")
            Divider()
            HStack(spacing: 12) {
                Button(action: onCopy) {
                    Label("复制图片", systemImage: "doc.on.doc")
                }
                Button(action: onToggleAllSpaces) {
                    Label(allSpaces ? "仅当前桌面" : "在所有桌面显示",
                          systemImage: allSpaces ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                }
                Spacer(minLength: 0)
                Text("拖动标题栏移动 · 拖动边缘缩放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(height: 42)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private final class PinnedImageWindow: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let image: NSImage
    private let onCopy: () -> Void
    private let onToggleAllSpaces: () -> Void
    private let onClose: () -> Void
    private let onFrameChanged: (NSRect) -> Void
    private let hosting: NSHostingView<PinnedImageContent>
    private var closeRequested = false

    init(
        record: PinnedImageRecord, image: NSImage, frame: NSRect,
        onCopy: @escaping () -> Void,
        onToggleAllSpaces: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onFrameChanged: @escaping (NSRect) -> Void
    ) {
        self.image = image
        self.onCopy = onCopy
        self.onToggleAllSpaces = onToggleAllSpaces
        self.onClose = onClose
        self.onFrameChanged = onFrameChanged
        hosting = NSHostingView(rootView: PinnedImageContent(
            image: image, allSpaces: record.allSpaces,
            onCopy: onCopy, onToggleAllSpaces: onToggleAllSpaces
        ))
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        panel = NSPanel(
            contentRect: NSWindow.contentRect(forFrameRect: frame, styleMask: style),
            styleMask: style,
            backing: .buffered, defer: false
        )
        super.init()
        panel.title = record.title
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 240, height: 180)
        panel.collectionBehavior = Self.collectionBehavior(allSpaces: record.allSpaces)
        panel.contentView = hosting
        panel.delegate = self
    }

    func show() {
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel.delegate = nil
        panel.close()
    }

    func update(allSpaces: Bool) {
        panel.collectionBehavior = Self.collectionBehavior(allSpaces: allSpaces)
        hosting.rootView = PinnedImageContent(
            image: image, allSpaces: allSpaces,
            onCopy: onCopy, onToggleAllSpaces: onToggleAllSpaces
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closeRequested else { return false }
        closeRequested = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.closeRequested = false
            self.onClose()
        }
        return false
    }

    func windowDidMove(_ notification: Notification) {
        onFrameChanged(panel.frame)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        onFrameChanged(panel.frame)
    }

    private static func collectionBehavior(allSpaces: Bool) -> NSWindow.CollectionBehavior {
        allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
    }
}

/// A separate floating window per image. These windows are intentionally not
/// owned by the shelf panel, which slides away after the pin action.
@MainActor
final class PinnedImageWindowManager {
    private let store: PinnedImageStore
    private let onChange: () -> Void
    private let onError: (String) -> Void
    private let onPasteboardWrite: (Int) -> Void
    private var windows: [UUID: PinnedImageWindow] = [:]
    private var frameTasks: [UUID: Task<Void, Never>] = [:]

    init(store: PinnedImageStore, onChange: @escaping () -> Void,
         onError: @escaping (String) -> Void,
         onPasteboardWrite: @escaping (Int) -> Void) {
        self.store = store
        self.onChange = onChange
        self.onError = onError
        self.onPasteboardWrite = onPasteboardWrite
    }

    func restore() {
        for record in store.records {
            do { try show(record) }
            catch { onError("恢复贴图失败：\(error.localizedDescription)") }
        }
    }

    func showAll() {
        for record in store.records {
            do { try show(record) }
            catch { onError("显示贴图失败：\(error.localizedDescription)") }
        }
    }

    func show(_ record: PinnedImageRecord) throws {
        if let existing = windows[record.id] {
            existing.show()
            return
        }
        guard let url = store.imageURL(for: record),
              let image = displayImage(at: url) else { throw PinnedImageError.missingSnapshot }
        let frame = fittedFrame(record.frame?.rect, imageSize: image.size)
        let window = PinnedImageWindow(
            record: record, image: image, frame: frame,
            onCopy: { [weak self] in self?.copy(record.id) },
            onToggleAllSpaces: { [weak self] in self?.toggleAllSpaces(record.id) },
            onClose: { [weak self] in self?.requestUnpin(record.id) },
            onFrameChanged: { [weak self] frame in self?.scheduleFrameSave(frame, for: record.id) }
        )
        windows[record.id] = window
        window.show()
    }

    func unpin(_ id: UUID) throws {
        if let window = windows[id] {
            frameTasks[id]?.cancel()
            frameTasks[id] = nil
            try store.remove(id)
            window.dismiss()
            windows[id] = nil
        } else {
            try store.remove(id)
        }
        onChange()
    }

    func unpinAll() throws {
        for id in store.records.map(\.id) { try unpin(id) }
    }

    func flushFrames() {
        for (id, window) in windows {
            frameTasks[id]?.cancel()
            do { try store.updateFrame(window.panel.frame, for: id) }
            catch { onError("保存贴图位置失败：\(error.localizedDescription)") }
        }
        frameTasks.removeAll()
    }

    private func copy(_ id: UUID) {
        guard let record = store.records.first(where: { $0.id == id }),
              let url = store.imageURL(for: record),
              let image = NSImage(contentsOf: url) else {
            onError(PinnedImageError.missingSnapshot.localizedDescription)
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.writeObjects([image]) else {
            onPasteboardWrite(board.changeCount)
            onError("复制贴图失败。")
            return
        }
        onPasteboardWrite(board.changeCount)
    }

    private func requestUnpin(_ id: UUID) {
        do { try unpin(id) }
        catch { onError("取消钉住失败：\(error.localizedDescription)") }
    }

    private func toggleAllSpaces(_ id: UUID) {
        guard let record = store.records.first(where: { $0.id == id }) else { return }
        do {
            let enabled = !record.allSpaces
            try store.setAllSpaces(enabled, for: id)
            windows[id]?.update(allSpaces: enabled)
        } catch {
            onError("切换桌面显示失败：\(error.localizedDescription)")
        }
    }

    private func scheduleFrameSave(_ frame: NSRect, for id: UUID) {
        frameTasks[id]?.cancel()
        frameTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            do { try self.store.updateFrame(frame, for: id) }
            catch { self.onError("保存贴图位置失败：\(error.localizedDescription)") }
            self.frameTasks[id] = nil
        }
    }

    private func fittedFrame(_ saved: NSRect?, imageSize: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let ratio = imageSize.height > 0 ? imageSize.width / imageSize.height : 1
        let preferredWidth = min(580, max(300, 520 * min(1.5, ratio)))
        let preferredHeight = min(680, max(260, preferredWidth / max(0.3, ratio) + 42))
        let validSaved = saved.flatMap { frame -> NSRect? in
            guard frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else { return nil }
            return frame
        }
        let proposed = validSaved ?? NSRect(
            x: visible.midX - preferredWidth / 2,
            y: visible.midY - preferredHeight / 2,
            width: preferredWidth, height: preferredHeight
        )
        let targetScreen = NSScreen.screens.first { $0.visibleFrame.intersects(proposed) }
            ?? screen
        let bounds = targetScreen?.visibleFrame ?? visible
        let width = min(max(240, proposed.width), bounds.width)
        let height = min(max(180, proposed.height), bounds.height)
        let x = min(max(proposed.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(proposed.minY, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func displayImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(
            width: thumbnail.width, height: thumbnail.height
        ))
    }
}
