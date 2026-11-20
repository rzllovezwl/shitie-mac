import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LongScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(size: CGSize, on screen: NSScreen) {
        let available = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        let width = min(frame.width, available.width)
        let height = min(frame.height, available.height)
        setFrame(CGRect(x: available.midX - width / 2, y: available.midY - height / 2,
                        width: width, height: height), display: false)
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        level = .floating
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }
}

@MainActor
final class MacLongScreenshotController: NSObject, NSWindowDelegate {
    private let state = LongScreenshotState()
    private var stripPanel: NSPanel?
    private var outlinePanel: NSPanel?
    private var previewWindow: NSWindow?
    private var worker: Task<Void, Never>?
    private var stitcher: LongScreenshotStitcher?
    private var generation = UUID()
    private var editRevision = 0
    private var atLimit = false
    private var escapeMonitor: Any?
    private var escapeKey: GlobalHotKey?
    private var onDismiss: (() -> Void)?

    var isPresenting: Bool { stripPanel != nil || previewWindow != nil }

    func begin(frame: MacScreenshotFrame, maximumBytes: Int,
               onSave: @escaping (MacScreenshotImage) -> Bool,
               onAnnotate: @escaping (CGImage, NSScreen) -> Bool,
               onDismiss: @escaping () -> Void) -> Bool {
        guard !isPresenting,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(frame.sourceFrame) }),
              let stitcher = LongScreenshotStitcher(frame.image) else { return false }
        self.stitcher = stitcher
        self.onDismiss = onDismiss
        let generation = UUID()
        self.generation = generation
        let area = frame.sourceFrame
        atLimit = false
        state.height = stitcher.height
        state.segments = 1
        state.canUndo = false
        state.canFinish = true
        state.message = "慢慢向下滚动，保留约三分之一重叠"

        let outline = makePanel(frame: area.insetBy(dx: -2, dy: -2))
        let border = NSView(frame: CGRect(origin: .zero, size: outline.frame.size))
        border.wantsLayer = true
        border.layer?.cornerRadius = 3
        border.layer?.borderWidth = 2
        border.layer?.borderColor = NSColor.systemBlue.cgColor
        outline.contentView = border
        outline.ignoresMouseEvents = true
        outlinePanel = outline

        let safe = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let hudSize = CGSize(width: min(430, safe.width), height: 78)
        var hudFrame = MacScreenshotGeometry.toolbarFrame(near: area, in: safe, size: hudSize, gap: 10)
        if hudFrame.intersects(area) {
            if area.maxX + 10 + hudSize.width <= safe.maxX {
                hudFrame.origin.x = area.maxX + 10
            } else if area.minX - 10 - hudSize.width >= safe.minX {
                hudFrame.origin.x = area.minX - 10 - hudSize.width
            }
        }
        let strip = makePanel(frame: hudFrame)
        strip.hasShadow = true
        strip.contentView = NSHostingView(rootView: LongScreenshotStrip(state: state,
            undo: { [weak self] in self?.undo() },
            finish: { [weak self] in
                self?.finish(on: screen, maximumBytes: maximumBytes, onSave: onSave, onAnnotate: onAnnotate)
            }, cancel: { [weak self] in self?.close() }))
        stripPanel = strip
        outline.orderFrontRegardless()
        strip.orderFrontRegardless()

        let esc = GlobalHotKey(identifier: 8) { [weak self] in self?.close() }
        if esc.registerEscape() {
            escapeKey = esc
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape), self?.stripPanel != nil else { return event }
            self?.close()
            return nil
        }
        let excluded: Set<CGWindowID> = [CGWindowID(strip.windowNumber), CGWindowID(outline.windowNumber)]
        let frontmost = NSWorkspace.shared.frontmostApplication
        let initialPID = frontmost?.bundleIdentifier == frame.source.bundleID
            ? frontmost?.processIdentifier : nil
        worker = Task { [weak self] in
            // Yield to the selector so its panel has left the screen.
            do {
                let sample = try await MacScreenshotCapture.longScreenshotSampler(for: area, excluding: excluded)
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(160))
                    guard let self, self.generation == generation, self.stripPanel != nil else { return }
                    guard !self.atLimit else { continue }
                    if let initialPID,
                       NSWorkspace.shared.frontmostApplication?.processIdentifier != initialPID {
                        self.state.message = "请切回原应用继续滚动"
                        continue
                    }
                    let image = try await sample()
                    guard let current = self.stitcher else { return }
                    let revision = self.editRevision
                    let result = await Task.detached(priority: .userInitiated) {
                        var next = current
                        let update = next.append(image)
                        return (next, update)
                    }.value
                    guard !Task.isCancelled, self.generation == generation else { return }
                    guard revision == self.editRevision else { continue }
                    self.stitcher = result.0
                    self.apply(result.1)
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.state.message = "采集已停止，可以完成并保留已截内容"
            }
        }
        return true
    }

    private func apply(_ update: LongScreenshotStitcher.Update) {
        guard let stitcher else { return }
        switch update {
        case .unchanged:
            if state.message == "请切回原应用继续滚动" {
                state.message = "慢慢向下滚动，保留约三分之一重叠"
            }
        case .appended:
            state.height = stitcher.height
            state.segments = stitcher.count
            state.canUndo = stitcher.canUndo
            state.message = "已拼接，可以继续向下滚动"
        case .noOverlap:
            state.message = "暂未找到重叠，往回滚一点再慢慢向下"
        case .limitReached:
            atLimit = true
            state.message = "已达长度上限，可以完成并预览"
        }
    }

    private func undo() {
        guard stitcher?.canUndo == true else { return }
        editRevision += 1
        atLimit = false
        stitcher?.undo()
        if let stitcher {
            state.height = stitcher.height
            state.segments = stitcher.count
        }
        state.canUndo = false
        state.message = "已撤回上一段，往回滚一点可继续拼接"
    }

    private func finish(on screen: NSScreen, maximumBytes: Int,
                        onSave: @escaping (MacScreenshotImage) -> Bool,
                        onAnnotate: @escaping (CGImage, NSScreen) -> Bool) {
        guard let stitcher, state.canFinish else { return }
        worker?.cancel()
        state.canFinish = false
        state.canUndo = false
        state.message = "正在生成长图…"
        let generation = generation
        worker = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { stitcher.image() }.value
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            guard let image else {
                self.state.canFinish = true
                self.state.message = "无法生成长图，请重试"
                return
            }
            self.worker = nil
            self.endCapture()
            let preview = LongScreenshotPreview(image: image, maximumBytes: maximumBytes,
                presentingWindow: { [weak self] in
                    guard let self, self.generation == generation else { return nil }
                    return self.previewWindow
                },
                onSave: { [weak self] result in
                    guard let self, self.generation == generation, self.previewWindow != nil,
                          onSave(result) else { return false }
                    self.close()
                    return true
                }, onAnnotate: { [weak self] image in
                    guard let self, self.generation == generation, self.previewWindow != nil,
                          onAnnotate(image, screen) else { return false }
                    self.close(notifyDismissal: false)
                    return true
                }, onCancel: { [weak self] in self?.close() })
            let window = LongScreenshotPanel(size: CGSize(width: 760, height: 660), on: screen)
            window.title = "长截图预览"
            window.minSize = CGSize(width: 630, height: 430)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: preview)
            previewWindow = window
            window.orderFrontRegardless()
            window.makeKey()
        }
    }

    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func endCapture() {
        worker?.cancel()
        worker = nil
        stripPanel?.orderOut(nil)
        outlinePanel?.orderOut(nil)
        stripPanel = nil
        outlinePanel = nil
        stitcher = nil
        escapeKey?.unregister()
        escapeKey = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func close(notifyDismissal: Bool = true) {
        generation = UUID()
        endCapture()
        let window = previewWindow
        previewWindow = nil
        window?.delegate = nil
        window?.close()
        let dismiss = onDismiss
        onDismiss = nil
        if notifyDismissal { dismiss?() }
    }

    func windowWillClose(_ notification: Notification) {
        previewWindow = nil
        close()
    }
}

@MainActor
private final class LongScreenshotState: ObservableObject {
    @Published var height = 0
    @Published var segments = 0
    @Published var message = ""
    @Published var canUndo = false
    @Published var canFinish = true
}

private struct LongScreenshotStrip: View {
    @ObservedObject var state: LongScreenshotState
    let undo: () -> Void
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("长截图", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    .fontWeight(.semibold)
                Spacer()
                Text("\(state.segments) 段 · \(state.height) px").monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(state.message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button("撤回", action: undo).disabled(!state.canUndo)
                    .help("撤回上一段")
                Button("取消", action: cancel)
                Button("完成", action: finish).disabled(!state.canFinish)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LongScreenshotPreview: View {
    let image: CGImage
    let maximumBytes: Int
    let presentingWindow: () -> NSWindow?
    let onSave: (MacScreenshotImage) -> Bool
    let onAnnotate: (CGImage) -> Bool
    let onCancel: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var actualSize = false
    @State private var top = 0
    @State private var bottom = 0
    @State private var busy = false
    @State private var message: String?
    @State private var oversized = false

    private var croppedImage: CGImage? {
        LongScreenshotOutput.trim(image, top: top, bottom: bottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(image.width) × \(image.height - top - bottom) px")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Picker("缩放", selection: $actualSize) {
                    Text("适合宽度").tag(false)
                    Text("100%").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 174)
            }
            GeometryReader { geometry in
                let scale = actualSize ? 1 / displayScale
                    : min(1 / displayScale, max(1, geometry.size.width - 24) / CGFloat(image.width))
                ScrollView([.vertical, .horizontal]) {
                    if let croppedImage {
                        Image(decorative: croppedImage, scale: 1)
                            .resizable().interpolation(.high)
                            .frame(width: CGFloat(croppedImage.width) * scale,
                                   height: CGFloat(croppedImage.height) * scale)
                            .padding(12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("裁剪顶部和底部") {
                VStack(alignment: .trailing, spacing: 8) {
                    trimRow("顶部", value: $top, limit: image.height - bottom - 1)
                    trimRow("底部", value: $bottom, limit: image.height - top - 1)
                    Button("重置") { top = 0; bottom = 0 }
                        .disabled(top == 0 && bottom == 0)
                }
                .padding(.top, 8)
                .disabled(busy)
                .onChange(of: top) { resetMessage() }
                .onChange(of: bottom) { resetMessage() }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("标注…") {
                    if let croppedImage, onAnnotate(croppedImage) { return }
                    message = "无法打开标注窗口，请重试。"
                }
                Button("保存到文件…") { encode(.file) }
                if oversized {
                    Button("缩小后复制") { encode(.resize) }.buttonStyle(.borderedProminent)
                } else {
                    Button("完成并复制") { encode(.history) }.buttonStyle(.borderedProminent)
                }
            }
            .disabled(busy)
        }
        .padding(16)
        .background {
            ShelfKeyMonitor { event in
                let shortcut = AppController.shared.shortcut(for: .saveImageToFile)
                guard !busy, let window = presentingWindow(), window.attachedSheet == nil,
                      shortcut.matches(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
                if !event.isARepeat { encode(.file) }
                return true
            }
            .frame(width: 0, height: 0)
        }
    }

    private func trimRow(_ title: String, value: Binding<Int>, limit: Int) -> some View {
        HStack {
            Text(title)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = min(limit, Int($0.rounded())) }),
                   in: 0...Double(max(1, limit)), step: 1)
                .accessibilityLabel("裁剪" + title)
                .disabled(limit == 0)
            Stepper(value: value, in: 0...limit) {
                Text("\(value.wrappedValue) px").monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    private func resetMessage() {
        message = nil
        oversized = false
    }

    private enum Output: Sendable { case history, resize, file }

    private func encode(_ output: Output) {
        guard !busy, let croppedImage else { return }
        busy = true
        message = "正在生成 PNG…"
        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) {
                switch output {
                case .history, .file: LongScreenshotOutput.png(croppedImage)
                case .resize: LongScreenshotOutput.png(croppedImage, fitting: maximumBytes)
                }
            }.value
            guard presentingWindow() != nil else { return }
            busy = false
            guard let data else {
                message = "无法生成长图，请尝试缩短裁剪范围后重试。"
                return
            }
            if output == .file {
                exportFile(data)
            } else if data.count > maximumBytes {
                oversized = true
                let limit = ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)
                message = "长图超过历史记录的单图上限（\(limit)）。可保存原尺寸 PNG，或缩小后复制并加入历史。"
            } else if !onSave(MacScreenshotImage(data: data, type: UTType.png.identifier)) {
                message = "未能保存到剪贴板历史。可以保存到文件或重试。"
            }
        }
    }

    private func exportFile(_ data: Data) {
        guard let window = presentingWindow(), window.attachedSheet == nil else { return }
        let panel = ImageFileExport.makePanel(name: ImageFileExport.suggestedName("长截图"))
        message = nil
        panel.beginSheetModal(for: window) { response in
            guard let url = ImageFileExport.destination(in: panel, response: response) else { return }
            do {
                try ImageFileExport.write(data, to: url)
                message = "已保存 \(url.lastPathComponent)"
            } catch {
                message = "无法写入文件。\(error.localizedDescription)"
            }
        }
    }
}
