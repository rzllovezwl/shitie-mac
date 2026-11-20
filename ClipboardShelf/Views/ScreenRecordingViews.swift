import AppKit
import AVKit
import SwiftUI

@MainActor
final class RecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        animationBehavior = .none
    }
}

/// Native glass on newer systems, with a readable native material on Sonoma.
@MainActor
private final class RecordingHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class RecordingGlassView<Content: View>: NSView {
    private let material: NSView
    private let host: NSHostingView<Content>
    init(rootView: Content) {
        host = RecordingHostingView(rootView: rootView)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            glass.contentView = host
            material = glass
        } else {
            let frost = NSVisualEffectView()
            frost.material = .popover
            frost.blendingMode = .behindWindow
            frost.state = .active
            frost.wantsLayer = true
            frost.layer?.cornerRadius = 16
            frost.layer?.masksToBounds = true
            frost.addSubview(host)
            material = frost
        }
        super.init(frame: .zero)
        addSubview(material)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        material.frame = bounds
        host.frame = material.bounds
    }
}

struct ScreenRecordingHUD: View {
    @ObservedObject var controller: ScreenRecordingController
    private var ready: Bool { controller.phase == .ready }
    private var active: Bool { controller.phase == .recording || controller.phase == .paused }
    var body: some View {
        HStack(spacing: 12) {
            if ready {
                Menu {
                    ForEach(ScreenRecordingScope.allCases) { scope in
                        Button { controller.select(scope: scope) } label: { Label(scope.title, systemImage: scope.symbol) }
                    }
                } label: {
                    Label(controller.preferences.scope.title, systemImage: controller.preferences.scope.symbol)
                }
                .fixedSize()
                Divider().frame(height: 22)
                icon(controller.preferences.systemAudio ? "speaker.wave.2" : "speaker.slash", "系统声音") {
                    controller.update { $0.systemAudio.toggle() }
                }
                .foregroundStyle(controller.preferences.systemAudio ? Color.accentColor : .secondary)
            } else {
                Circle().fill(controller.phase == .paused ? Color.orange : .red).frame(width: 8, height: 8)
                Text(active ? controller.timeLabel : controller.phase.title)
                    .monospacedDigit().font(.system(size: 15, weight: .semibold))
                if controller.phase == .paused { Text("暂停").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
            }
            if ready || active {
                icon(controller.preferences.microphone ? "mic" : "mic.slash", "麦克风") { controller.toggleMicrophone() }
                    .foregroundStyle(controller.preferences.microphone ? Color.accentColor : .secondary)
                    .disabled(controller.changingMicrophone)
            }
            if ready {
                Menu {
                    Section("画面") {
                        Picker("清晰度", selection: preference(\.quality)) {
                            ForEach(ScreenRecordingQuality.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("帧率", selection: preference(\.frameRate)) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                        Picker("倒计时", selection: preference(\.countdown)) { Text("不倒计时").tag(0); Text("3 秒").tag(3); Text("5 秒").tag(5) }
                        Toggle("显示鼠标指针", isOn: preference(\.showsCursor))
                        Toggle("突出鼠标点击", isOn: preference(\.highlightsClicks))
                        Toggle("录制时显示控制条", isOn: preference(\.showsControls))
                    }
                    Section("麦克风") {
                        Picker("输入设备", selection: preference(\.microphoneDeviceID)) {
                            Text("系统默认").tag(String?.none)
                            ForEach(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(Optional(device.uniqueID))
                            }
                        }
                    }
                    Divider()
                    Button("录屏设置…") { controller.cancel(); controller.onSettings?() }
                } label: { Image(systemName: "slider.horizontal.3") }
                .help("录屏选项")
                Spacer(minLength: 0)
                icon("xmark", "取消 · Esc") { controller.cancel() }
                Button { controller.start() } label: {
                    Image(systemName: "play.fill").font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.green).frame(width: 34, height: 34)
                }
                .buttonStyle(.plain).help("开始录制 · \(controller.recordShortcut)").accessibilityLabel("开始录制")
            } else if active {
                icon(controller.phase == .paused ? "play.fill" : "pause.fill", "暂停 / 继续 · \(controller.pauseShortcut)") {
                    controller.togglePause()
                }
                .foregroundStyle(controller.phase == .paused ? Color.green : Color.primary)
                icon("eye.slash", "隐藏控制条（可从菜单栏恢复）") { controller.hideControls() }
                Divider().frame(height: 22)
                Button { Task { await controller.stop() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.red).frame(width: 34, height: 34)
                }.buttonStyle(.plain).help("结束录制并预览 · \(controller.recordShortcut)").accessibilityLabel("结束录制并预览")
            } else if controller.phase.canCancel {
                icon("xmark", "取消 · Esc") { controller.cancel() }
            } else { ProgressView().controlSize(.small) }
        }
        .font(.system(size: 16, weight: .medium))
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 20).frame(height: 64)
        .help(controller.message ?? controller.sourceName)
    }
    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 32).contentShape(Rectangle()) }
            .help(help).accessibilityLabel(help)
    }
    private func preference<T>(_ key: WritableKeyPath<ScreenRecordingPreferences, T>) -> Binding<T> {
        Binding(get: { controller.preferences[keyPath: key] }, set: { value in controller.update { $0[keyPath: key] = value } })
    }
}

@MainActor
final class RecordingSelectionView: NSView {
    var selection: CGRect { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var adjustable: Bool
    var isRecording = false { didSet { needsDisplay = true } }
    var countdown: Int? { didSet { needsDisplay = true } }
    var onChange: ((CGRect) -> Void)?
    private var start: CGPoint = .zero
    private var original: CGRect = .zero
    private var handle: Int?
    private var moving = false
    private var constraint = MacScreenshotDragConstraint()
    init(frame: CGRect, selection: CGRect, adjustable: Bool) {
        self.selection = selection; self.adjustable = adjustable
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    private var anchors: [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.midX, y: selection.minY),
         CGPoint(x: selection.maxX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.midY),
         CGPoint(x: selection.maxX, y: selection.maxY), CGPoint(x: selection.midX, y: selection.maxY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.minX, y: selection.midY)]
    }
    override func draw(_ dirtyRect: NSRect) {
        if !isRecording {
            let shade = NSBezierPath(rect: bounds)
            shade.append(NSBezierPath(rect: selection))
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.25).setFill(); shade.fill()
        }
        (isRecording ? NSColor.systemRed.withAlphaComponent(0.8) : NSColor.systemBlue).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1)); border.lineWidth = 1; border.stroke()
        if adjustable && !isRecording {
            NSColor.systemBlue.setFill()
            for point in anchors { NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2).fill() }
        }
        if let countdown {
            let text = "\(countdown)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 72, weight: .semibold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            let rect = CGRect(x: selection.midX - 62, y: selection.midY - 62, width: 124, height: 124)
            NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(ovalIn: rect).fill()
            text.draw(at: CGPoint(x: selection.midX - size.width / 2, y: selection.midY - size.height / 2), withAttributes: attributes)
        }
    }
    override func resetCursorRects() {
        guard adjustable && !isRecording else { return }
        addCursorRect(selection.insetBy(dx: 14, dy: 14), cursor: .openHand)
        for (index, point) in anchors.enumerated() {
            addCursorRect(CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28),
                cursor: index == 1 || index == 5 ? .resizeUpDown : .resizeLeftRight)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard adjustable, !isRecording, countdown == nil else { return }
        start = convert(event.locationInWindow, from: nil); original = selection
        handle = anchors.enumerated().min(by: { hypot($0.element.x - start.x, $0.element.y - start.y) < hypot($1.element.x - start.x, $1.element.y - start.y) })
            .flatMap { hypot($0.element.x - start.x, $0.element.y - start.y) <= 18 ? $0.offset : nil }
        moving = handle == nil && selection.contains(start)
        constraint.reset(modifiers: event.modifierFlags)
    }
    override func mouseDragged(with event: NSEvent) {
        guard adjustable, !isRecording, countdown == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let handle {
            let opposite = anchorsFor(original)[(handle + 4) % 8]
            let rect: CGRect
            if [1, 3, 5, 7].contains(handle), !event.modifierFlags.contains(.option) {
                if handle == 1 || handle == 5 {
                    rect = CGRect(x: original.minX, y: min(opposite.y, p.y), width: original.width, height: max(2, abs(opposite.y - p.y)))
                } else { rect = CGRect(x: min(opposite.x, p.x), y: original.minY, width: max(2, abs(opposite.x - p.x)), height: original.height) }
            } else { rect = constraint.rect(from: opposite, to: p, in: bounds, modifiers: event.modifierFlags) }
            if rect.width >= 2, rect.height >= 2 { selection = rect.intersection(bounds) }
        } else if moving {
            var dx = p.x - start.x, dy = p.y - start.y
            if event.modifierFlags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            var rect = original.offsetBy(dx: dx, dy: dy)
            rect.origin.x = min(max(bounds.minX, rect.minX), bounds.maxX - rect.width)
            rect.origin.y = min(max(bounds.minY, rect.minY), bounds.maxY - rect.height)
            selection = rect
        } else { return }
        onChange?(selection)
    }
    override func mouseUp(with event: NSEvent) { handle = nil; moving = false }
    private func anchorsFor(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }
}

struct ScreenRecordingMenu: View {
    @ObservedObject var recorder: ScreenRecordingController
    var body: some View {
        if recorder.phase == .idle {
            Button { recorder.toggle() } label: { Label("录屏…（\(recorder.recordShortcut)）", systemImage: "play.fill") }
        } else if recorder.phase == .awaitingSave {
            Button("查看待保存录屏…") { recorder.reviewPendingDraft() }
        } else if recorder.phase.canCancel {
            Button("取消录屏准备") { recorder.cancel() }
        } else {
            Text("\(recorder.phase.title) · \(recorder.timeLabel)")
            if recorder.phase == .recording || recorder.phase == .paused {
                Button("\(recorder.phase == .paused ? "继续" : "暂停")录制（\(recorder.pauseShortcut)）") { recorder.togglePause() }
                Button("显示录屏控制条") { recorder.showControls() }
                if let message = recorder.message { Text(message) }
            }
            Button { Task { await recorder.stop() } } label: {
                Label("结束并预览（\(recorder.recordShortcut)）", systemImage: "stop.fill")
            }
                .disabled(recorder.phase == .finishing || recorder.phase == .saving)
        }
    }
}

struct RecordingMenuBarLabel: View {
    @ObservedObject var recorder: ScreenRecordingController
    @ObservedObject var copyAnimation: MenuBarCopyAnimation
    var body: some View {
        HStack(spacing: 4) {
            if recorder.phase.isCapturing || recorder.phase == .finishing {
                Image(systemName: recorder.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
                    .foregroundStyle(recorder.phase == .paused ? Color.orange : .red)
                Text(recorder.timeLabel).monospacedDigit()
            } else { Image(nsImage: copyAnimation.image) }
        }.accessibilityLabel(recorder.phase.isActive ? recorder.phase.title : "ClipHoook")
    }
}

@MainActor
final class ScreenRecordingPreviewController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var player: AVPlayer?
    private var fileAccess: FilePreviewAccess?
    private var isSavingDraft = false
    private var draftEdits: RecordingDraftEdits?

    func showDraft(_ draft: ScreenRecordingDraft,
                   updateEdits: @escaping (ScreenRecordingTrim?, ScreenRecordingQuality) throws -> Void,
                   save: @escaping (URL) async throws -> Void,
                   discard: @escaping () throws -> Void) {
        if draftEdits?.isTrimming == true { window?.makeKeyAndOrderFront(nil); return }
        close()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first else { return }
        let panel = LongScreenshotPanel(size: CGSize(width: 780, height: 560), on: screen)
        panel.title = "录屏预览 · 待保存"
        panel.delegate = self
        let player = AVPlayer(url: draft.movie.url)
        self.player = player
        let edits = RecordingDraftEdits(draft: draft, player: player, onChange: updateEdits)
        draftEdits = edits
        panel.contentView = NSHostingView(rootView: RecordingDraftResultView(movie: draft.movie, player: player, edits: edits,
            save: { [weak self, weak panel] finished in
                guard let self, let panel else { finished(nil); return }
                self.saveDraft(draft, window: panel, action: save, finished: finished)
            }, discard: { [weak self] in
                try discard()
                self?.close()
            }))
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    private func saveDraft(_ draft: ScreenRecordingDraft, window: NSWindow,
                           action: @escaping (URL) async throws -> Void,
                           finished: @escaping (String?) -> Void) {
        let directory: URL
        do { directory = try ScreenRecordingDestination.directory() }
        catch { finished(error.localizedDescription); return }
        let panel = NSSavePanel()
        panel.title = "保存录屏"
        panel.prompt = "保存"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = draft.movie.url.lastPathComponent
        panel.directoryURL = directory
        isSavingDraft = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let destination = panel.url else {
                directory.stopAccessingSecurityScopedResource()
                self?.isSavingDraft = false
                finished(nil)
                return
            }
            let access = destination.startAccessingSecurityScopedResource()
            Task { @MainActor in
                defer {
                    if access { destination.stopAccessingSecurityScopedResource() }
                    directory.stopAccessingSecurityScopedResource()
                    self?.isSavingDraft = false
                }
                do { try await action(destination); finished(nil) }
                catch { finished(error.localizedDescription) }
            }
        }
    }
    func show(_ movie: ScreenRecordingMovie, access: FilePreviewAccess?, copy: @escaping () -> Void, history: @escaping () -> Void) {
        close()
        fileAccess = access
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first else { return }
        let panel = LongScreenshotPanel(size: CGSize(width: 780, height: 560), on: screen)
        panel.title = "录屏预览"
        panel.delegate = self
        let player = AVPlayer(url: movie.url)
        self.player = player
        panel.contentView = NSHostingView(rootView: RecordingResultView(movie: movie, player: player, copy: copy,
            save: { Self.saveAs(movie.url, window: panel) }, history: { [weak self] in self?.close(); history() }))
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }
    func close() {
        draftEdits?.pausePreview()
        player?.pause(); player = nil
        window?.orderOut(nil); window = nil
        fileAccess = nil; draftEdits = nil
    }
    func windowWillClose(_ notification: Notification) { close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isSavingDraft && draftEdits?.isTrimming != true }
    static func saveAs(_ url: URL, window: NSWindow? = nil, retaining access: FilePreviewAccess? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "screenRecording.exportDirectory")
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path)
        let complete: (NSApplication.ModalResponse) -> Void = { result in
            defer { withExtendedLifetime(access) {} }
            guard result == .OK, let destination = panel.url, destination.standardizedFileURL != url.standardizedFileURL else { return }
            let access = destination.startAccessingSecurityScopedResource()
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            do {
                // A temporary sibling preserves an existing file if copying fails.
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: url, to: temporary)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                UserDefaults.standard.set(destination.deletingLastPathComponent().path, forKey: "screenRecording.exportDirectory")
            } catch { NSAlert(error: error).runModal() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
}

private struct RecordingPlayer: NSViewRepresentable {
    let player: AVPlayer
    var edits: RecordingDraftEdits? = nil
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        edits?.attach(view)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        edits?.attach(view)
    }
}

@MainActor
private final class RecordingDraftEdits: ObservableObject {
    @Published private(set) var trim: ScreenRecordingTrim?
    @Published private(set) var quality: ScreenRecordingQuality
    @Published private(set) var isTrimming = false
    @Published private(set) var isReady = false
    @Published private(set) var error: String?
    private let movie: ScreenRecordingMovie
    private let player: AVPlayer
    private let onChange: (ScreenRecordingTrim?, ScreenRecordingQuality) throws -> Void
    private weak var playerView: AVPlayerView?
    private var observation: NSKeyValueObservation?
    private var positionedInitialSelection = false

    init(draft: ScreenRecordingDraft, player: AVPlayer,
         onChange: @escaping (ScreenRecordingTrim?, ScreenRecordingQuality) throws -> Void) {
        movie = draft.movie
        trim = draft.trim
        quality = draft.quality
        self.player = player
        self.onChange = onChange
        applyPlaybackBounds()
    }

    var selection: ScreenRecordingTrim { trim ?? .init(start: 0, end: movie.duration) }
    var canTrim: Bool { isReady && playerView != nil }
    var rangeLabel: String {
        let range = selection
        return "\(time(range.start)) – \(time(range.end)) · 保留 \(String(format: "%.2f", range.duration)) 秒"
    }
    private func time(_ seconds: Double) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }

    func attach(_ view: AVPlayerView) {
        guard playerView !== view else { return }
        playerView = view
        observation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let ready = item.status == .readyToPlay
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReady = ready
                if ready, !self.positionedInitialSelection {
                    self.positionedInitialSelection = true
                    if self.trim != nil {
                        self.player.seek(to: CMTime(seconds: self.selection.start, preferredTimescale: 60_000),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            }
        }
    }

    func beginTrimming() {
        guard !isTrimming, let view = playerView else { return }
        guard view.canBeginTrimming else { error = "视频仍在准备裁剪，请稍后再试。"; return }
        pausePreview()
        error = nil
        isTrimming = true
        view.beginTrimming { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isTrimming = false }
                if result == .okButton, let item = self.player.currentItem {
                    let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
                    let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : self.movie.duration
                    self.persist(trim: .init(start: start, end: end), quality: self.quality)
                }
                self.applyPlaybackBounds()
                self.player.seek(to: CMTime(seconds: self.selection.start, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    func setQuality(_ quality: ScreenRecordingQuality) { persist(trim: trim, quality: quality) }
    func pausePreview() { player.pause() }
    func reset() {
        pausePreview()
        persist(trim: nil, quality: quality)
        applyPlaybackBounds()
        player.seek(to: CMTime(seconds: selection.start, preferredTimescale: 60_000))
    }

    private func persist(trim: ScreenRecordingTrim?, quality: ScreenRecordingQuality) {
        do {
            let range = try trim?.validated(duration: movie.duration, frameRate: movie.frameRate)
            let full = range?.isFullRange(duration: movie.duration, frameRate: movie.frameRate) == true
            let next = full ? nil : range
            try onChange(next, quality)
            self.trim = next
            self.quality = quality
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func applyPlaybackBounds() {
        player.currentItem?.reversePlaybackEndTime = trim.map { CMTime(seconds: $0.start, preferredTimescale: 60_000) } ?? .invalid
        player.currentItem?.forwardPlaybackEndTime = trim.map { CMTime(seconds: $0.end, preferredTimescale: 60_000) } ?? .invalid
    }
}

private struct RecordingDraftResultView: View {
    let movie: ScreenRecordingMovie
    let player: AVPlayer
    @ObservedObject var edits: RecordingDraftEdits
    let save: (@escaping (String?) -> Void) -> Void
    let discard: () throws -> Void
    @State private var busy = false
    @State private var error: String?
    @State private var confirmsDiscard = false
    var body: some View {
        VStack(spacing: 0) {
            RecordingPlayer(player: player, edits: edits).frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!busy)
            Divider()
            HStack(spacing: 12) {
                Button { edits.beginTrimming() } label: { Label("裁剪时长", systemImage: "scissors") }
                    .disabled(!edits.canTrim)
                if edits.trim != nil { Button("恢复完整") { edits.reset() } }
                Spacer(minLength: 8)
                Picker("画质", selection: Binding(get: { edits.quality }, set: { edits.setQuality($0) })) {
                    ForEach(ScreenRecordingQuality.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 185)
            }.padding(.horizontal, 16).padding(.vertical, 10).disabled(busy || edits.isTrimming)
            if let error = edits.error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 16) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 16) }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("待保存 · \(movie.width) × \(movie.height) · \(movie.frameRate) fps")
                    Text(edits.rangeLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text("确认保存后加入历史；关闭窗口保留片段与裁剪范围。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("放弃", role: .destructive) { confirmsDiscard = true }
                Button("保存…") {
                    edits.pausePreview()
                    busy = true
                    error = nil
                    save { message in error = message; busy = false }
                }.buttonStyle(.borderedProminent)
            }.padding(16).disabled(busy || edits.isTrimming)
        }
        .frame(minWidth: 480, minHeight: 300)
        .confirmationDialog("放弃这段录屏？", isPresented: $confirmsDiscard) {
            Button("放弃录屏", role: .destructive) {
                edits.pausePreview()
                do { try discard() } catch { self.error = error.localizedDescription }
            }
        } message: { Text("片段尚未保存，放弃后将删除。") }
    }
}
private struct RecordingResultView: View {
    let movie: ScreenRecordingMovie
    let player: AVPlayer
    let copy: () -> Void
    let save: () -> Void
    let history: () -> Void
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            RecordingPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(movie.url.lastPathComponent).lineLimit(1)
                    Text("已保存 · \(movie.width) × \(movie.height) · \(movie.frameRate) fps · \(sizeLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { copy(); copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.help("复制视频文件")
                Button(action: save) { Image(systemName: "square.and.arrow.down") }.help("另存为…")
                Button(action: history) { Image(systemName: "list.clipboard") }.help("在剪贴板中查看")
                Button { NSWorkspace.shared.activateFileViewerSelecting([movie.url]) } label: { Image(systemName: "folder") }.help("在访达中显示")
            }.padding(16).buttonStyle(.borderless).font(.system(size: 16))
        }.frame(minWidth: 480, minHeight: 300)
    }
    private var sizeLabel: String {
        let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
