import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A recording owns one stream and one app-owned draft. Only explicit save
/// confirmation exports it and notifies clipboard history.
/// Selection/countdown are separate from capture so Escape cannot discard a recording.
@MainActor
final class ScreenRecordingController: NSObject, ObservableObject, SCStreamDelegate {
    private static let captureBackground = CGColor(gray: 0, alpha: 1)
    @Published private(set) var phase: ScreenRecordingPhase = .idle
    @Published var preferences = ScreenRecordingPreferences()
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var sourceName = ""
    @Published private(set) var message: String?
    @Published private(set) var changingMicrophone = false
    var onPreparing: (() -> Void)?
    var onPreparationEnded: (() -> Void)?
    var onSaved: ((ScreenRecordingMovie, MacScreenshotSource, Bool) -> Void)?
    var onReviewDraft: ((ScreenRecordingDraft, Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onSettings: (() -> Void)?
    @Published var recordShortcut = "⌥R"
    @Published var pauseShortcut = "⌥⇧R"

    private let selector = MacScreenshotCapture()
    private var selection: MacScreenshotCapture.Selection?
    private var screen: NSScreen?
    private var area: CGRect = .zero
    private var source = MacScreenshotSource.desktop
    private var displayID: CGDirectDisplayID = 0
    private var hud: RecordingPanel?
    private var overlay: RecordingPanel?
    private var overlayView: RecordingSelectionView?
    private var stream: SCStream?
    private var writer: ScreenRecordingWriter?
    private var microphone: ScreenRecordingMicrophone?
    private var task: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var exportTask: Task<Void, Error>?
    private var token = UUID()
    private var timer: Timer?
    private var startedAt: Double?
    private var pausedAt: Double?
    private var pauseDuration: Double = 0
    private var escapeLocal: Any?
    private var escapeGlobal: Any?
    private var escapeKey: GlobalHotKey?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let draftStore = ScreenRecordingDraftStore(directory: ScreenRecordingDraftStore.defaultDirectory)
    private(set) var pendingDraft: ScreenRecordingDraft?
    private var preparationOpen = false
    private var previewsResult = true

    var timeLabel: String {
        ClipboardRecordingMetadata(duration: elapsed, width: 0, height: 0, frameRate: 0).durationLabel
    }
    var isPreparing: Bool {
        phase == .selecting || phase == .ready || phase.canCancel || phase == .starting
    }

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.stop(openPreview: false) }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in await self?.stop(openPreview: false) } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase.isActive else { return }
                    if !NSScreen.screens.contains(where: { Self.id($0) == self.displayID }) { await self.stop() }
                }
            })
    }

    func toggle() {
        if phase == .idle { begin() }
        else if phase == .awaitingSave { reviewPendingDraft() }
        else if phase == .ready { start() }
        else if phase.canCancel { cancel() }
        else { Task { await stop() } }
    }

    func begin(scope: ScreenRecordingScope? = nil) {
        guard phase == .idle else { return }
        preferences = ScreenRecordingPreferences()
        if let scope { preferences.scope = scope }
        message = nil
        elapsed = 0
        previewsResult = true
        token = UUID()
        preparationOpen = true
        onPreparing?()
        select(scope: preferences.scope)
    }

    func select(scope: ScreenRecordingScope) {
        guard phase == .idle || phase == .ready || phase == .selecting else { return }
        selector.cancelRecordingSelection()
        closePanels()
        preferences.scope = scope
        preferences.save()
        phase = .selecting
        let current = token
        selector.selectForRecording(scope: scope) { [weak self] result in
            guard let self, current == self.token, self.phase == .selecting else { return }
            switch result {
            case .failure(let error):
                self.cancel()
                if (error as? MacScreenshotError) != .cancelled { self.onError?(error.localizedDescription) }
            case .success(let selection): self.prepare(selection)
            }
        }
    }

    private func prepare(_ selection: MacScreenshotCapture.Selection) {
        let frame: CGRect
        switch selection {
        case .region(let rect): frame = rect; preferences.scope = .region
        case .window(_, let rect): frame = rect; preferences.scope = .window
        case .screen(let rect): frame = rect; preferences.scope = .screen
        }
        guard let screen = NSScreen.screens.max(by: {
            $0.frame.intersection(frame).recordingArea < $1.frame.intersection(frame).recordingArea
        }), frame.width >= 2, frame.height >= 2 else { cancel(); return }
        self.selection = selection
        self.screen = screen
        displayID = Self.id(screen)
        area = frame
        source = MacScreenshotCapture.sourceApp(for: frame)
        sourceName = preferences.scope == .screen ? screen.localizedName : source.name
        preferences.save()
        phase = .ready
        let panel = RecordingPanel(frame: screen.frame)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        let canvas = RecordingSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
            selection: frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
            adjustable: preferences.scope == .region)
        canvas.onChange = { [weak self] rect in
            guard let self, self.phase == .ready else { return }
            self.area = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            self.selection = .region(self.area)
            self.positionHUD()
        }
        panel.contentView = canvas
        overlay = panel
        overlayView = canvas
        panel.orderFrontRegardless()
        showControls()
        installEscape()
    }

    func update(_ change: (inout ScreenRecordingPreferences) -> Void) {
        change(&preferences)
        preferences.save()
    }

    func start() {
        guard phase == .ready, task == nil else { return }
        preferences.save()
        message = nil
        let current = token
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if self.preferences.microphone { try await self.authorizeMicrophone() }
                try Task.checkCancellation()
                self.overlayView?.adjustable = false
                if self.preferences.countdown > 0 {
                    for count in stride(from: self.preferences.countdown, through: 1, by: -1) {
                        guard self.token == current else { throw CancellationError() }
                        self.phase = .countdown(count)
                        self.overlayView?.countdown = count
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                try Task.checkCancellation()
                guard self.token == current else { return }
                self.phase = .starting
                self.overlayView?.countdown = nil
                self.overlayView?.isRecording = true
                self.overlay?.ignoresMouseEvents = true
                self.removeEscape()
                try await self.startStream(token: current)
            } catch is CancellationError { }
            catch {
                guard self.token == current else { return }
                self.failBeforeStart(error)
            }
        }
    }

    private func startStream(token current: UUID) async throws {
        guard let screen, let selection else { throw ScreenRecordingError.unavailableSource }
        if let blocked = MacScreenshotCapture.unsharedWindowName(in: selection,
            mainScreenTop: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) {
            throw ScreenRecordingError.failed("“\(blocked)”不允许截取画面，无法录制该范围。请换一个窗口或区域。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard current == token, let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenRecordingError.unavailableSource
        }
        let filter: SCContentFilter
        if case .window(let windowID, _) = selection {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenRecordingError.unavailableSource
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            if let app = window.owningApplication {
                source = MacScreenshotSource(name: app.applicationName, bundleID: app.bundleIdentifier)
                sourceName = source.name
            }
        } else {
            source = MacScreenshotCapture.sourceApp(for: area)
            let excludedIDs = Set([hud, overlay].compactMap { $0 }.map { CGWindowID($0.windowNumber) })
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter {
                excludedIDs.contains($0.windowID)
            })
        }
        let config = SCStreamConfiguration()
        let dimensions = preferences.quality.dimensions(for: area.size, scale: CGFloat(filter.pointPixelScale))
        config.width = Int(dimensions.width)
        config.height = Int(dimensions.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(preferences.frameRate))
        config.queueDepth = 4
        config.showsCursor = preferences.showsCursor
        config.capturesAudio = preferences.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        config.backgroundColor = Self.captureBackground
        if case .region = selection {
            let desktopRect = MacScreenshotGeometry.displayRect(for: area,
                mainScreenTop: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)
            config.sourceRect = desktopRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        }
        let directory = try draftStore.makeWorkspace()
        let urls = ScreenRecordingDestination.urls(in: directory)
        let writer = try ScreenRecordingWriter(temporaryURL: urls.temporary, finalURL: urls.final,
            dimensions: dimensions, frameRate: preferences.frameRate,
            systemAudio: preferences.systemAudio, microphone: preferences.microphone,
            onFirstFrame: { [weak self] in
                Task { @MainActor in
                    guard let self, self.token == current, self.phase == .starting else { return }
                    self.startedAt = Self.now
                    self.pauseDuration = 0
                    self.phase = .recording
                    self.endPreparation()
                    self.installTimer()
                    if !self.preferences.showsControls { self.hud?.orderOut(nil) }
                }
            }, onFailure: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.token == current, self.phase.isCapturing else { return }
                    self.message = error.localizedDescription
                    await self.stop()
                }
            })
        self.writer = writer
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if preferences.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        if preferences.microphone {
            let mic = ScreenRecordingMicrophone()
            microphone = mic
            try await mic.start(deviceID: preferences.microphoneDeviceID, writer: writer)
        }
        try Task.checkCancellation()
        try await stream.startCapture()
        try Task.checkCancellation()
        installClickMonitor()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.token == current, self.phase == .starting else { return }
            self.message = ScreenRecordingError.noFrames.localizedDescription
            await self.stop()
        }
    }

    func togglePause() {
        guard phase == .recording || phase == .paused, let writer else { return }
        let now = Self.now
        if phase == .recording {
            phase = .paused
            pausedAt = now
            Task { await writer.pause(at: now) }
        } else {
            if case .window(let id, _) = selection,
               let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
               info[kCGWindowIsOnscreen as String] as? Bool == false { return }
            pauseDuration += max(0, now - (pausedAt ?? now))
            pausedAt = nil
            phase = .recording
            message = nil
            Task { await writer.resume(at: now) }
        }
    }

    func toggleMicrophone() {
        guard !changingMicrophone else { return }
        if phase == .ready { update { $0.microphone.toggle() }; return }
        guard phase == .recording || phase == .paused, let writer else { return }
        let operationToken = token
        changingMicrophone = true
        Task {
            defer { changingMicrophone = false }
            do {
                if preferences.microphone {
                    preferences.microphone = false
                    writer.setMicrophoneEnabled(false)
                    await microphone?.stop()
                    microphone = nil
                } else {
                    try await authorizeMicrophone()
                    guard token == operationToken, self.writer === writer,
                          phase == .recording || phase == .paused else { return }
                    let mic = ScreenRecordingMicrophone()
                    try await mic.start(deviceID: preferences.microphoneDeviceID, writer: writer)
                    guard token == operationToken, self.writer === writer,
                          phase == .recording || phase == .paused else { await mic.stop(); return }
                    microphone = mic
                    preferences.microphone = true
                    writer.setMicrophoneEnabled(true)
                }
                preferences.save()
            } catch { message = error.localizedDescription; onError?(error.localizedDescription) }
        }
    }

    func stop(openPreview: Bool = true) async {
        if !openPreview { previewsResult = false }
        if let exportTask { _ = try? await exportTask.value; return }
        if let finishTask { await finishTask.value; return }
        if phase.canCancel { cancel(); return }
        guard phase.isCapturing else { return }
        phase = .finishing
        task?.cancel()
        let job = Task { [weak self] in await self?.finishRecording() }
        finishTask = Task { _ = await job.value }
        await finishTask?.value
        finishTask = nil
    }

    private func finishRecording() async {
        timer?.invalidate(); timer = nil
        removeClickMonitor()
        if let writer { await writer.pause(at: Self.now) }
        try? await stream?.stopCapture()
        await microphone?.stop()
        stream = nil
        microphone = nil
        do {
            guard let writer else { throw ScreenRecordingError.noFrames }
            let movie = try await writer.finish()
            let draft = try draftStore.stage(movie, sourceName: source.name, sourceBundleID: source.bundleID)
            let preview = previewsResult
            reset()
            pendingDraft = draft
            phase = .awaitingSave
            onReviewDraft?(draft, preview)
        } catch {
            reset()
            onError?(error.localizedDescription)
        }
    }

    func restorePendingDraft() {
        guard phase == .idle, let draft = draftStore.pendingDrafts().first else { return }
        pendingDraft = draft
        phase = .awaitingSave
    }

    func reviewPendingDraft() {
        guard phase == .awaitingSave, let pendingDraft else { return }
        onReviewDraft?(pendingDraft, true)
    }

    func updatePendingDraft(trim: ScreenRecordingTrim?, quality: ScreenRecordingQuality) throws {
        guard phase == .awaitingSave, let pendingDraft else {
            throw ScreenRecordingError.failed("当前片段不可编辑，请等待保存完成。")
        }
        self.pendingDraft = try draftStore.update(pendingDraft, trim: trim, quality: quality)
    }

    func savePendingDraft(to destination: URL) async throws {
        guard phase == .awaitingSave, let draft = pendingDraft else {
            throw ScreenRecordingError.failed("当前没有待保存的录屏。")
        }
        phase = .saving
        let store = draftStore
        let job = Task { [self] in
            do {
                let movie = try await store.saveReviewed(draft, to: destination)
                pendingDraft = nil
                phase = .idle
                // Called only after the explicit confirmation and atomic export.
                onSaved?(movie, MacScreenshotSource(name: draft.sourceName, bundleID: draft.sourceBundleID), true)
                restorePendingDraft()
            } catch {
                phase = .awaitingSave
                throw error
            }
        }
        exportTask = job
        defer { exportTask = nil }
        try await job.value
    }

    func discardPendingDraft() throws {
        guard phase == .awaitingSave, let pendingDraft else { return }
        try draftStore.discard(pendingDraft)
        self.pendingDraft = nil
        phase = .idle
        restorePendingDraft()
    }

    func cancel() {
        guard phase.canCancel || phase == .idle else { return }
        task?.cancel(); task = nil
        token = UUID()
        selector.cancelRecordingSelection()
        reset()
    }

    private func failBeforeStart(_ error: Error) {
        let oldStream = stream
        let mic = microphone
        stream = nil; microphone = nil
        writer?.discard(); writer = nil
        Task { try? await oldStream?.stopCapture(); await mic?.stop() }
        reset()
        onError?(error.localizedDescription)
    }

    private func reset() {
        task = nil
        removeEscape()
        removeClickMonitor()
        timer?.invalidate(); timer = nil
        closePanels()
        writer = nil
        selection = nil
        startedAt = nil; pausedAt = nil
        phase = .idle
        endPreparation()
    }

    private func endPreparation() {
        guard preparationOpen else { return }
        preparationOpen = false
        onPreparationEnded?()
    }

    func showControls() {
        guard phase != .idle else { return }
        if hud == nil {
            let panel = RecordingPanel(frame: CGRect(x: 0, y: 0, width: 570, height: 64))
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.contentView = RecordingGlassView(rootView: ScreenRecordingHUD(controller: self))
            hud = panel
        }
        positionHUD()
        hud?.orderFrontRegardless()
    }

    func hideControls() { hud?.orderOut(nil) }

    private func positionHUD() {
        guard let hud, let screen else { return }
        let safe = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        hud.setFrame(MacScreenshotGeometry.toolbarFrame(near: area, in: safe,
            size: CGSize(width: min(570, safe.width), height: 64), gap: 12), display: true)
    }

    private func closePanels() {
        hud?.orderOut(nil); hud = nil
        overlay?.orderOut(nil); overlay = nil; overlayView = nil
    }

    private func installEscape() {
        removeEscape()
        let key = GlobalHotKey(identifier: 22) { [weak self] in
            if self?.phase.canCancel == true { self?.cancel() }
        }
        if key.registerEscape() { escapeKey = key }
        escapeLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { if self?.phase.canCancel == true { self?.cancel() } }
            return nil
        }
        escapeGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { Task { @MainActor in if self?.phase.canCancel == true { self?.cancel() } } }
        }
    }
    private func removeEscape() {
        escapeKey?.unregister(); escapeKey = nil
        if let escapeLocal { NSEvent.removeMonitor(escapeLocal) }; escapeLocal = nil
        if let escapeGlobal { NSEvent.removeMonitor(escapeGlobal) }; escapeGlobal = nil
    }
    private func installClickMonitor() {
        guard preferences.highlightsClicks else { return }
        let receive: (NSEvent) -> Void = { [weak self] _ in
            // AppKit delivers both monitor callbacks on the main thread.
            // Sample the pointer immediately, before another event moves it.
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                let point = NSEvent.mouseLocation
                guard self.area.contains(point), self.hud?.frame.contains(point) != true else { return }
                self.writer?.showClick(at: CGPoint(x: (point.x - self.area.minX) / self.area.width,
                    y: (self.area.maxY - point.y) / self.area.height), hostTime: Self.now)
            }
        }
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: types, handler: receive)
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { event in
            receive(event)
            return event
        }
    }
    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }; clickMonitor = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }; localClickMonitor = nil
    }
    private func installTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording || self.phase == .paused else { return }
                self.elapsed = max(0, (self.pausedAt ?? Self.now) - (self.startedAt ?? Self.now) - self.pauseDuration)
                if case .window(let id, _) = self.selection {
                    let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
                    if info.isEmpty { await self.stop() }
                    else if (info.first?[kCGWindowIsOnscreen as String] as? Bool) == false, self.phase == .recording {
                        self.message = "窗口已最小化，录制已暂停；恢复窗口后点击继续。"
                        self.togglePause()
                    }
                }
            }
        }
    }
    private func authorizeMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            // The high-level selector must not cover the system's first-use
            // permission dialog. Keep the same windows/IDs for stream exclusion.
            let restoreHUD = hud?.isVisible == true
            let restoreOverlay = overlay?.isVisible == true
            let permissionToken = token
            removeEscape()
            hud?.orderOut(nil); overlay?.orderOut(nil)
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            if phase.isActive, token == permissionToken {
                if restoreOverlay { overlay?.orderFrontRegardless() }
                if restoreHUD { hud?.orderFrontRegardless() }
                if phase.canCancel { installEscape() }
            }
            guard allowed else { throw ScreenRecordingError.microphoneDenied }
        default: throw ScreenRecordingError.microphoneDenied
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream, self.phase.isCapturing else { return }
            self.message = error.localizedDescription
            await self.stop()
        }
    }
    private static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    private static func id(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

private extension CGRect {
    var recordingArea: CGFloat { isNull ? 0 : max(0, width) * max(0, height) }
}

@MainActor
enum ScreenRecordingDestination {
    static let bookmarkKey = "screenRecording.directoryBookmark"
    static let pathKey = "screenRecording.directoryPath"
    static var label: String {
        UserDefaults.standard.string(forKey: pathKey) ?? "下载 / ClipHoook"
    }
    static func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择录屏保存位置"
        panel.prompt = "选择文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let bookmark = try url.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
                UserDefaults.standard.set(url.path, forKey: pathKey)
                NotificationCenter.default.post(name: .recordingDestinationChanged, object: nil)
            } catch { NSAlert(error: error).runModal() }
        }
    }
    static func directory() throws -> URL {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &stale)
            _ = url.startAccessingSecurityScopedResource()
            if stale, let refreshed = try? url.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil) { defaults.set(refreshed, forKey: bookmarkKey) }
            return url
        }
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ScreenRecordingError.failed("找不到下载文件夹，请在录屏设置中选择保存位置。")
        }
        let url = downloads.appendingPathComponent("ClipHoook", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func urls(in directory: URL) -> (temporary: URL, final: URL) {
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "录屏 \(date.string(from: .now)) \(UUID().uuidString.prefix(4))"
        return (directory.appendingPathComponent(".\(name).recording.mp4"),
                directory.appendingPathComponent("\(name).mp4"))
    }
}

extension Notification.Name {
    static let recordingDestinationChanged = Notification.Name("ClipHoookRecordingDestinationChanged")
}
