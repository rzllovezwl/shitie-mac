import AppKit
import Carbon
import Combine
import ImageIO
import UniformTypeIdentifiers

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    static let preferenceKey = "appAppearanceMode"

    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum PhoneScreenshotDiscovery {
    static let onboardingHandledKey = "phoneScreenshotOnboardingHandledV1"
    static let cardDismissedKey = "phoneScreenshotFeatureCardDismissedV1"
    static let completedStepsKey = "phoneScreenshotCompletedGuideStepsV1"
}

enum PinnedImageDiscovery {
    static let gestureTipShownKey = "pinnedImageGestureTipShownV3"
}

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController(store: ClipboardHistoryStore())
    private static let pastePermissionMessage = "已复制，请手动按 ⌘V。若已允许键盘事件，请退出并重新打开 ClipHoook。"
    private static let copiedMessage = "已复制到剪贴板"

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var favoriteCategories: [ClipboardFavoriteCategory] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var toastMessage: String?
    @Published private(set) var hotKeyRegistered = false
    @Published private(set) var quickSearchHotKeyRegistered = false
    @Published private(set) var registeredScreenshotHotKeys: Set<AppShortcutAction> = []
    var regionCaptureHotKeyRegistered: Bool { registeredScreenshotHotKeys.contains(.captureRegion) }
    @Published private(set) var shortcuts: [AppShortcutAction: AppShortcut] = [:]
    @Published private(set) var previewActionRequest: ClipboardPreviewActionRequest?

    func requestPreviewAction(_ action: AppShortcutAction, for entry: ClipboardEntry) {
        previewActionRequest = ClipboardPreviewActionRequest(entryID: entry.id, action: action)
    }
    func clearPreviewAction() { previewActionRequest = nil }
    var openPanelShortcut: AppShortcut { shortcut(for: .openPanel) }
    var deleteEntryShortcut: AppShortcut { shortcut(for: .deleteEntry) }

    func shortcut(for action: AppShortcutAction) -> AppShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }
    @Published private(set) var needsPastePermission = false
    @Published private(set) var panelPresentationID = UUID()
    @Published private(set) var excludedApplications: [ExcludedApplication] = []
    @Published private(set) var historyStorageBytes: Int64 = 0
    @Published private(set) var migrationBackupBytes: Int64 = 0
    @Published private(set) var recoveryBytes: Int64 = 0
    @Published private(set) var pinnedImageCount = 0
    @Published private(set) var pinnedStorageBytes: Int64 = 0
    @Published private(set) var stagingItemCount = 0
    @Published private(set) var imageOCRInProgress: Set<UUID> = []
    @Published private(set) var imageOCRErrors: [UUID: String] = [:]
    @Published private(set) var isSearchingImageText = false
    private var recoveringFileCopy = false
    @Published private(set) var phoneScreenshotReceivingEnabled: Bool
    @Published private(set) var phoneScreenshotReceiverStatus = "未开启"
    @Published private(set) var phoneScreenshotLastSetupVisitAt: Date?
    @Published private(set) var phoneScreenshotLastUploadResult = "本次运行尚未收到截图"
    @Published private(set) var showsPhoneScreenshotFeatureCard: Bool
    @Published private(set) var phoneScreenshotEndpoint: String
    @Published private(set) var phoneScreenshotSetupAddress: String
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: "recordingPaused") }
    }

    private let store: ClipboardHistoryStore
    private var pinnedStore: PinnedImageStore?
    private var pinnedWindows: PinnedImageWindowManager?
    private var stagingShelf: StagingShelfController?
    private var phoneScreenshotReceiver: PhoneScreenshotReceiver?
    private var phoneScreenshotReceiverGeneration = UUID()
    private let hotKey = GlobalHotKey { AppController.shared.togglePanel() }
    private let quickSearchHotKey = GlobalHotKey(identifier: 11) {
        AppController.shared.toggleQuickSearch()
    }
    private let regionCaptureHotKey = GlobalHotKey(identifier: 2) {
        AppController.shared.beginMacScreenshot(.region)
    }
    private let screenCaptureHotKey = GlobalHotKey(identifier: 10) {
        AppController.shared.beginMacScreenshot(.screen)
    }
    private let translateCaptureHotKey = GlobalHotKey(identifier: 6) {
        AppController.shared.beginMacScreenshot(.region, startAction: .translate)
    }
    private let ocrCaptureHotKey = GlobalHotKey(identifier: 7) {
        AppController.shared.beginMacScreenshot(.region, startAction: .recognizeText)
    }
    private let longCaptureHotKey = GlobalHotKey(identifier: 9) {
        AppController.shared.beginMacScreenshot(.long)
    }
    private let recordScreenHotKey = GlobalHotKey(identifier: 20) { AppController.shared.toggleScreenRecording() }
    private let pauseRecordingHotKey = GlobalHotKey(identifier: 21) { AppController.shared.screenRecorder.togglePause() }
    private var screenshotHotKeys: [(AppShortcutAction, GlobalHotKey)] {
        [(.captureRegion, regionCaptureHotKey), (.captureScreen, screenCaptureHotKey),
         (.captureTranslate, translateCaptureHotKey),
         (.captureRecognizeText, ocrCaptureHotKey), (.captureLongScreenshot, longCaptureHotKey),
         (.recordScreen, recordScreenHotKey), (.pauseScreenRecording, pauseRecordingHotKey)]
    }
    let screenRecorder = ScreenRecordingController()
    let menuBarCopyAnimation = MenuBarCopyAnimation()
    private let recordingPreview = ScreenRecordingPreviewController()
    private let screenshotCapture = MacScreenshotCapture()
    private let longScreenshot = MacLongScreenshotController()
    private let screenshotEditor = MacScreenshotEditorController()
    // An existing image stays editable while a separate screenshot is selected
    // and annotated. Opening the new capture must not replace its canvas.
    private let imageEditor = MacScreenshotEditorController()
    private var activatePinnedImageAfterScreenshot = false
    private var screenshotFailureNotice: NSPanel?
    private var screenshotFailureNoticeTask: Task<Void, Never>?
    private lazy var panel = PanelController(model: self)
    private lazy var quickSearch = QuickSearchController(model: self)
    private var suspendedShelfForSearch = false
    private let pasteFallbackPanel = PasteFallbackPanelController()
    private let pasteFocusHandoff = PasteFocusHandoff()
    private var timer: Timer?
    private var toastDismissTask: Task<Void, Never>?
    private var pinnedGestureHintTask: Task<Void, Never>?
    private var lastHotKeyAttempt = Date.distantPast
    private var lastQuickSearchHotKeyAttempt = Date.distantPast
    private var lastScreenshotHotKeyAttempt = Date.distantPast
    private var isRecordingShortcut = false
    private var hotKeyConflictMessageShown: String?
    private var lastHistoryCleanup = Date.distantPast
    private var lastStorageRefresh = Date.distantPast
    private var storageRefreshPending = false
    private var clipboardChanges: ClipboardChangeTracker
    private var started = false
    private var didStartOCRPreparation = false
    private var imageTextSearchScope: ClipboardImageSearchScope?
    private var imageTextSearchTask: Task<Void, Never>?
    private var imageSearchPublicationTask: Task<Void, Never>?
    private var attemptedImageSearchIDs: Set<UUID> = []
    private var foregroundActivationCount = 0
    private var activationCountAtLastPoll = 0
    private var lastPolledForegroundBundleID: String?
    private var activationObserver: NSObjectProtocol?
    private let filePreviewCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()

    init(store: ClipboardHistoryStore) {
        self.store = store
        showsPhoneScreenshotFeatureCard = !UserDefaults.standard.bool(
            forKey: PhoneScreenshotDiscovery.cardDismissedKey
        )
        phoneScreenshotReceivingEnabled = UserDefaults.standard.bool(
            forKey: PhoneScreenshotReceiver.enabledKey
        )
        let phoneScreenshotToken = PhoneScreenshotReceiver.token()
        phoneScreenshotEndpoint = PhoneScreenshotReceiver.endpoint(token: phoneScreenshotToken)
        phoneScreenshotSetupAddress = PhoneScreenshotReceiver.setupAddress(token: phoneScreenshotToken)
        let shortcutResolution = AppShortcutPreference.resolved()
        shortcuts = shortcutResolution.shortcuts
        clipboardChanges = ClipboardChangeTracker(initialChangeCount: NSPasteboard.general.changeCount)
        isPaused = UserDefaults.standard.bool(forKey: "recordingPaused")
        entries = store.rootEntries
        favoriteCategories = store.favoriteCategories
        statusMessage = store.errorMessage ?? (shortcutResolution.adjusted.isEmpty ? nil
            : "部分快捷键与已有自定义按键冲突，已分配可用按键；请在设置中查看和修改。")
        excludedApplications = RecordingExclusionPolicy.applications(in: .standard)
        screenRecorder.recordShortcut = shortcut(for: .recordScreen).displayName
        screenRecorder.pauseShortcut = shortcut(for: .pauseScreenRecording).displayName
        screenRecorder.onPreparing = { [weak self] in
            self?.quickSearch.dismiss(restore: false)
            self?.stagingShelf?.beginScreenshotInteraction()
            self?.panel.beginScreenshotInteraction()
        }
        screenRecorder.onPreparationEnded = { [weak self] in self?.endMacScreenshotInteraction() }
        screenRecorder.onSettings = { [weak self] in self?.openSettings(category: .screenRecording) }
        screenRecorder.onError = { [weak self] message in
            self?.statusMessage = message
            self?.showScreenshotFailureNotice(message)
        }
        screenRecorder.onReviewDraft = { [weak self] draft, presentsPreview in
            guard let self, presentsPreview else { return }
            self.recordingPreview.showDraft(draft, updateEdits: { [weak self] trim, quality in
                guard let self else { throw ScreenRecordingError.cancelled }
                try self.screenRecorder.updatePendingDraft(trim: trim, quality: quality)
            }, save: { [weak self] destination in
                guard let self else { throw ScreenRecordingError.cancelled }
                try await self.screenRecorder.savePendingDraft(to: destination)
            }, discard: { [weak self] in
                try self?.screenRecorder.discardPendingDraft()
            })
        }
        screenRecorder.onSaved = { [weak self] movie, source, preview in
            guard let self else { return }
            do {
                _ = try self.store.addFileReference(movie.url, sourceAppName: source.name,
                    sourceAppBundleID: source.bundleID,
                    screenRecording: .init(duration: movie.duration, width: movie.width,
                        height: movie.height, frameRate: movie.frameRate))
                self.entries = self.store.rootEntries
                self.refreshStorageSizes()
                if preview, let entry = self.store.entries.first(where: { $0.filePath == movie.url.path }) {
                    self.recordingPreview.show(movie, access: self.store.filePreviewAccess(for: entry), copy: { [weak self] in self?.copy(entry) }, history: { [weak self] in
                        self?.panelPresentationID = UUID()
                        self?.panel.show()
                    })
                }
            } catch {
                self.showScreenshotFailureNotice("视频已保存在“\(movie.url.lastPathComponent)”，但加入历史失败：\(error.localizedDescription)")
                NSWorkspace.shared.activateFileViewerSelecting([movie.url])
            }
        }
        screenRecorder.restorePendingDraft()
        refreshStorageSizes()
    }

    func toggleScreenRecording() {
        screenRecorder.recordShortcut = shortcut(for: .recordScreen).displayName
        screenRecorder.pauseShortcut = shortcut(for: .pauseScreenRecording).displayName
        if screenRecorder.phase == .idle {
            guard !screenshotCapture.isActive, !screenshotEditor.isPresenting,
                  !imageEditor.isPresenting, !longScreenshot.isPresenting,
                  NSApp.modalWindow == nil else {
                showToast("请先完成或取消当前操作"); return
            }
            recordingPreview.close()
        }
        screenRecorder.toggle()
    }

    func openSettings(category: SettingsCategory? = nil, onClose: (() -> Void)? = nil) {
        quickSearch.dismiss(restore: false)
        refreshStorageSizes()
        pinnedGestureHintTask?.cancel()
        pinnedGestureHintTask = nil
        pinnedWindows?.dismissGestureHint()
        SettingsWindowController.shared.prepareToOpen()
        // Wait until the screen-level panel has finished leaving the screen.
        // Otherwise its deferred focus promotion can cover the first Settings
        // window, leaving only the Dock icon visible.
        panel.hide(restorePreviousApplication: false) {
            SettingsWindowController.shared.open(category: category, onClose: onClose)
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openPhoneScreenshotGuide() {
        pinnedGestureHintTask?.cancel()
        pinnedGestureHintTask = nil
        pinnedWindows?.dismissGestureHint()
        panel.hide(restorePreviousApplication: false) {
            PhoneScreenshotGuideWindowController.shared.open()
        }
    }

    func dismissPhoneScreenshotFeatureCard() {
        UserDefaults.standard.set(true, forKey: PhoneScreenshotDiscovery.cardDismissedKey)
        showsPhoneScreenshotFeatureCard = false
    }

    func start() {
        guard !started else { return }
        started = true
        updateAppearance(UserDefaults.standard.string(forKey: AppAppearanceMode.preferenceKey))
        if case .needsPermission = PasteService.availability(requestPermission: false) {
            needsPastePermission = true
        }
        _ = CopySoundPlayer.shared
        _ = panel
        configurePinnedImages()
        configureStagingShelf()
        prepareOCRIfNeeded()
        if phoneScreenshotReceivingEnabled { startPhoneScreenshotReceiver() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.foregroundActivationCount += 1 }
        }
        retryHotKeyIfNeeded()
        retryQuickSearchHotKeyIfNeeded()
        retryScreenshotHotKeysIfNeeded()
        let captureTimer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryHotKeyIfNeeded()
                self?.retryQuickSearchHotKeyIfNeeded()
                self?.retryScreenshotHotKeysIfNeeded()
                self?.refreshPastePermission()
                self?.cleanHistoryIfNeeded()
                if self?.storageRefreshPending == true {
                    self?.refreshStorageSizes(force: false)
                }
                self?.pollPasteboard()
            }
        }
        timer = captureTimer
        RunLoop.main.add(captureTimer, forMode: .common)
        if !UserDefaults.standard.bool(forKey: PhoneScreenshotDiscovery.onboardingHandledKey) {
            if store.isNewInstallation {
                DispatchQueue.main.async {
                    PhoneScreenshotGuideWindowController.shared.open()
                    UserDefaults.standard.set(true, forKey: PhoneScreenshotDiscovery.onboardingHandledKey)
                }
            } else {
                UserDefaults.standard.set(true, forKey: PhoneScreenshotDiscovery.onboardingHandledKey)
            }
        }
    }

    func setPhoneScreenshotReceivingEnabled(_ enabled: Bool) {
        guard phoneScreenshotReceivingEnabled != enabled else { return }
        phoneScreenshotReceivingEnabled = enabled
        phoneScreenshotLastSetupVisitAt = nil
        phoneScreenshotLastUploadResult = "本次接收会话尚未收到截图"
        UserDefaults.standard.set(enabled, forKey: PhoneScreenshotReceiver.enabledKey)
        if enabled {
            startPhoneScreenshotReceiver()
        } else {
            phoneScreenshotReceiverGeneration = UUID()
            phoneScreenshotReceiver?.stop()
            phoneScreenshotReceiver = nil
            phoneScreenshotReceiverStatus = "未开启"
        }
    }

    /// The old iPhone upload and setup links stop working after this action.
    /// This must only be called from an explicit confirmation in Settings.
    func resetPhoneScreenshotPairingCode() {
        phoneScreenshotReceiverGeneration = UUID()
        phoneScreenshotReceiver?.stop()
        phoneScreenshotReceiver = nil
        let token = PhoneScreenshotReceiver.rotateToken()
        phoneScreenshotEndpoint = PhoneScreenshotReceiver.endpoint(token: token)
        phoneScreenshotSetupAddress = PhoneScreenshotReceiver.setupAddress(token: token)
        phoneScreenshotLastSetupVisitAt = nil
        phoneScreenshotLastUploadResult = "配对码已重置，等待更新 iPhone 模板地址"
        let defaults = UserDefaults.standard
        let completed = defaults.integer(forKey: PhoneScreenshotDiscovery.completedStepsKey)
        defaults.set(completed & ~((1 << 1) | (1 << 3)),
                     forKey: PhoneScreenshotDiscovery.completedStepsKey)
        phoneScreenshotReceiverStatus = "正在更新接收地址…"
        if phoneScreenshotReceivingEnabled {
            let generation = phoneScreenshotReceiverGeneration
            Task { @MainActor [weak self] in
                // NWListener releases its port after cancel() returns. Wait for
                // the old listener before binding the same port with a new key.
                try? await Task.sleep(for: .milliseconds(350))
                guard let self,
                      self.phoneScreenshotReceiverGeneration == generation,
                      self.phoneScreenshotReceivingEnabled,
                      self.phoneScreenshotReceiver == nil else { return }
                self.startPhoneScreenshotReceiver()
            }
        } else {
            phoneScreenshotReceiverStatus = "未开启"
        }
    }

    func copyPhoneScreenshotEndpoint() {
        copyProtectedAddress(phoneScreenshotEndpoint)
    }

    func copyPhoneScreenshotSetupAddress() {
        copyProtectedAddress(phoneScreenshotSetupAddress)
    }

    private func copyProtectedAddress(_ address: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(address, forType: .string)
        // The pairing URL is a secret, so never record our own settings copy.
        clipboardChanges.markOwnWrite(changeCount: board.changeCount)
    }

    private func startPhoneScreenshotReceiver() {
        guard phoneScreenshotReceiver == nil else { return }
        phoneScreenshotReceiverStatus = "正在启动…"
        let generation = UUID()
        phoneScreenshotReceiverGeneration = generation
        let receiver = PhoneScreenshotReceiver(
            token: PhoneScreenshotReceiver.token(),
            onImage: { [weak self] data, completion in
                Task { @MainActor [weak self] in
                    guard let self, self.phoneScreenshotReceiverGeneration == generation else {
                        completion(.rejected)
                        return
                    }
                    completion(self.importPhoneScreenshot(data))
                }
            },
            onState: { [weak self] status in
                Task { @MainActor [weak self] in
                    guard self?.phoneScreenshotReceivingEnabled == true,
                          self?.phoneScreenshotReceiverGeneration == generation else { return }
                    self?.phoneScreenshotReceiverStatus = status
                }
            },
            onSetupVisit: { [weak self] in
                Task { @MainActor [weak self] in
                    guard self?.phoneScreenshotReceivingEnabled == true,
                          self?.phoneScreenshotReceiverGeneration == generation else { return }
                    self?.phoneScreenshotLastSetupVisitAt = .now
                }
            }
        )
        do {
            try receiver.start()
            phoneScreenshotReceiver = receiver
        } catch {
            phoneScreenshotReceiverStatus = "接收失败：\(error.localizedDescription)"
            phoneScreenshotReceivingEnabled = false
            UserDefaults.standard.set(false, forKey: PhoneScreenshotReceiver.enabledKey)
        }
    }

    private func importPhoneScreenshot(_ data: Data) -> PhoneScreenshotReceiver.ImportResult {
        guard phoneScreenshotReceivingEnabled else {
            phoneScreenshotLastUploadResult = "收到上传，但 Mac 接收已关闭"
            return .rejected
        }
        guard !isPaused else {
            phoneScreenshotLastUploadResult = "收到上传，但当前已暂停记录"
            return .rejected
        }
        guard data.count <= store.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "public.heic", "public.heif",
               "com.compuserve.gif", "public.tiff"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              Int64(width) * Int64(height) <= 100_000_000
        else {
            phoneScreenshotLastUploadResult = "收到上传，但图片格式或大小不符合要求"
            return .rejected
        }
        do {
            let saved = try store.importPhoneScreenshot(data, type: type)
            if saved {
                entries = store.rootEntries
                prepareOCRIfNeeded()
                refreshStorageSizes(force: false)
                CopySoundPlayer.shared.playIfEnabled(.chime)
                statusMessage = "已收到 iPhone 截图"
                phoneScreenshotLastUploadResult = "已收到新截图：\(DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .short))"
                phoneScreenshotReceiverStatus = "已就绪，最近收到截图：\(DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .short))"
                return .saved
            }
            phoneScreenshotLastUploadResult = "收到重复截图，未新增卡片"
            return .alreadySaved
        } catch {
            statusMessage = "保存 iPhone 截图失败：\(error.localizedDescription)"
            phoneScreenshotLastUploadResult = "收到上传，但保存失败：\(error.localizedDescription)"
            return .rejected
        }
    }

    func togglePanel() {
        guard !panel.isEditingText, !(NSApp.modalWindow is NSSavePanel) else { return }
        if quickSearch.isPresented {
            let resume = suspendedShelfForSearch
            quickSearch.dismiss(restore: resume)
            if resume { return }
        }
        cancelPasteHandoff()
        if panel.isVisible {
            panel.hide()
        } else {
            pasteFallbackPanel.dismiss()
            dismissToast()
            if statusMessage == Self.copiedMessage
                || statusMessage?.hasPrefix("已复制，请手动按 ⌘V") == true {
                statusMessage = nil
            }
            panelPresentationID = UUID()
            panel.show()
            remindAboutUncappedHistoryIfNeeded()
        }
    }

    func closePanel() {
        panel.hide()
    }

    func currentHistoryEntry(_ id: UUID) -> ClipboardEntry? {
        entries.first { $0.id == id } ?? entries.lazy.flatMap(\.groupMembers).first { $0.id == id }
    }

    func toggleQuickSearch() {
        guard NSApp.modalWindow == nil, !screenRecorder.isPreparing, !isRecordingShortcut, !panel.isEditingText,
              !panel.isCardDragActive, !screenshotCapture.isActive,
              !screenshotEditor.isPresenting, !imageEditor.isPresenting,
              !longScreenshot.isPresenting else { return }
        if quickSearch.isPresented { quickSearch.dismiss(); return }
        cancelPasteHandoff()
        pasteFallbackPanel.dismiss()
        dismissToast()
        let foreground = NSWorkspace.shared.frontmostApplication
        let isOwnApp = foreground?.processIdentifier == NSRunningApplication.current.processIdentifier
        let application = isOwnApp ? (panel.isVisible ? panel.previousApplication : nil) : foreground
        let target = isOwnApp ? (panel.isVisible ? panel.previousTarget : nil) : application.flatMap {
            PasteTargetSnapshot.capture(for: $0.processIdentifier)
        }
        let oldSearchScope = imageTextSearchScope
        setImageTextSearchScope(nil)
        suspendedShelfForSearch = panel.suspendForQuickSearch()
        SettingsWindowController.shared.prepareForPanelPresentation()
        pasteFocusHandoff.isSearchInteractionActive = true
        quickSearch.show(application: application, target: target) { [weak self] restore in
            guard let self else { return }
            self.pasteFocusHandoff.isSearchInteractionActive = false
            let resumesShelf = restore && self.suspendedShelfForSearch
            self.suspendedShelfForSearch = false
            if resumesShelf {
                self.panel.resumeAfterQuickSearch()
                self.setImageTextSearchScope(oldSearchScope)
            } else {
                SettingsWindowController.shared.restoreAfterPanelPresentation()
                if restore, let application, !application.isTerminated { _ = application.activate() }
            }
        }
    }

    func beginMacScreenshot(_ mode: MacScreenshotMode, startAction: ScreenshotStartAction = .annotate) {
        guard NSApp.modalWindow == nil else { return }
        guard !screenRecorder.isPreparing else { return }
        if mode == .long, screenshotEditor.canStartLongScreenshot {
            screenshotEditor.startLongScreenshot()
            return
        }
        guard !screenshotCapture.isActive, !screenshotEditor.isPresenting, !longScreenshot.isPresenting else {
            statusMessage = "请先完成或取消当前截图。"
            return
        }
        dismissScreenshotFailureNotice()
        quickSearch.dismiss(restore: false)
        imageEditor.setScreenshotInteractionActive(true)
        activatePinnedImageAfterScreenshot = false
        stagingShelf?.beginScreenshotInteraction()
        panel.beginScreenshotInteraction()
        statusMessage = nil
        screenshotCapture.begin(
            mode, freezeDesktop: ScreenshotFreezePreference.isEnabled(),
            selectionHints: startAction.selectionHints
        ) { [weak self] result in
            self?.finishMacScreenshot(result, mode: mode, startAction: startAction)
        }
    }

    private func endMacScreenshotInteraction() {
        imageEditor.setScreenshotInteractionActive(false)
        panel.endScreenshotInteraction()
        stagingShelf?.endScreenshotInteraction()
    }

    private func finishMacScreenshot(_ result: Result<MacScreenshotFrame, Error>,
                                     mode: MacScreenshotMode, startAction: ScreenshotStartAction) {
        switch result {
        case .failure(let error):
            endMacScreenshotInteraction()
            statusMessage = error is MacScreenshotError &&
                (error as? MacScreenshotError) == .cancelled
                ? nil : "\(mode.title)失败：\(error.localizedDescription)"
            if let screenshotError = error as? MacScreenshotError {
                switch screenshotError {
                case .windowNotShared, .contentUnavailable, .noWindow, .noImage:
                    showScreenshotFailureNotice(error.localizedDescription)
                default:
                    break
                }
            }
        case .success(let frame):
            if mode == .long {
                if !beginLongScreenshot(frame) {
                    endMacScreenshotInteraction()
                    showScreenshotFailureNotice("请拖选足够大的可滚动内容区域，然后重试。")
                }
                return
            }
            if !screenshotEditor.openInline(
                    image: frame.image, sourceFrame: frame.sourceFrame,
                    selectionPanel: frame.selectionPanel,
                    isWindowCapture: frame.isWindowCapture,
                    frozenDisplay: frame.frozenDisplay, startAction: startAction,
                    maximumBytes: store.maximumImageBytes,
                    saveFailureMessage: { [weak self] in self?.statusMessage },
                    onSave: { [weak self] finalImage, editable in
                        guard let self else { return false }
                        return self.saveCapturedScreenshot(
                            finalImage, editable: editable, mode: mode,
                            source: self.screenshotEditor.inlineSourceFrame == frame.sourceFrame
                                ? frame.source
                                : MacScreenshotCapture.sourceApp(
                                    for: self.screenshotEditor.inlineSourceFrame ?? frame.sourceFrame,
                                    excludingWindowID: self.screenshotEditor.inlineOverlayWindowID)
                        )
                    },
                    onPin: { [weak self] finalImage, editable in
                        guard let self else { return false }
                        return self.saveCapturedScreenshot(
                            finalImage, editable: editable, mode: mode,
                            source: self.screenshotEditor.inlineSourceFrame == frame.sourceFrame
                                ? frame.source
                                : MacScreenshotCapture.sourceApp(
                                    for: self.screenshotEditor.inlineSourceFrame ?? frame.sourceFrame,
                                    excludingWindowID: self.screenshotEditor.inlineOverlayWindowID),
                            pinAfterSave: true,
                            pinContentFrame: self.screenshotEditor.inlineSourceFrame
                        )
                    },
                    onLongScreenshot: { [weak self] frame in
                        self?.beginLongScreenshot(frame) ?? false
                    },
                    onCancel: { [weak self] in self?.statusMessage = nil },
                    onDismiss: { [weak self] in
                        guard let self else { return }
                        self.endMacScreenshotInteraction()
                        if self.activatePinnedImageAfterScreenshot {
                            self.activatePinnedImageAfterScreenshot = false
                            self.panel.activateForPinnedImageInteraction()
                        }
                    }
                  ) {
                endMacScreenshotInteraction()
                statusMessage = "无法打开截图标注界面，请重试。"
            }
        }
    }

    private func beginLongScreenshot(_ frame: MacScreenshotFrame) -> Bool {
        let source = frame.source
        let started = longScreenshot.begin(frame: frame, maximumBytes: store.maximumImageBytes,
            onSave: { [weak self] image in
                self?.saveCapturedScreenshot(image, mode: .long, source: source) ?? false
            },
            onAnnotate: { [weak self] image, screen in
                guard let self, !self.screenshotEditor.isPresenting else { return false }
                return self.screenshotEditor.openLongScreenshot(image: image, on: screen,
                    maximumBytes: self.store.maximumImageBytes,
                    saveFailureMessage: { [weak self] in self?.statusMessage },
                    onClose: { [weak self] in self?.endMacScreenshotInteraction() },
                    onSave: { [weak self] result, editable in
                        self?.saveCapturedScreenshot(result, editable: editable,
                                                     mode: .long, source: source) ?? false
                    })
            },
            onDismiss: { [weak self] in self?.endMacScreenshotInteraction() })
        if started { statusMessage = nil }
        return started
    }

    private func showScreenshotFailureNotice(_ message: String) {
        dismissScreenshotFailureNotice()
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main else { return }
        let width = min(560, screen.visibleFrame.width - 32)
        let height: CGFloat = 110
        let frame = CGRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.maxY - height - 20,
            width: width, height: height
        )
        let notice = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        notice.isOpaque = false
        notice.backgroundColor = .clear
        notice.hasShadow = true
        notice.level = .popUpMenu
        notice.ignoresMouseEvents = true
        notice.hidesOnDeactivate = false
        notice.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let material = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.masksToBounds = true
        let title = NSTextField(labelWithString: "截图未保存")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        material.addSubview(title)
        material.addSubview(detail)
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -18),
            title.topAnchor.constraint(equalTo: material.topAnchor, constant: 14),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: material.bottomAnchor, constant: -12)
        ])
        notice.contentView = material
        screenshotFailureNotice = notice
        notice.orderFrontRegardless()
        screenshotFailureNoticeTask = Task { @MainActor [weak self, weak notice] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self,
                  self.screenshotFailureNotice === notice else { return }
            self.dismissScreenshotFailureNotice()
        }
    }

    private func dismissScreenshotFailureNotice() {
        screenshotFailureNoticeTask?.cancel()
        screenshotFailureNoticeTask = nil
        screenshotFailureNotice?.orderOut(nil)
        screenshotFailureNotice = nil
    }

    private func saveCapturedScreenshot(_ image: MacScreenshotImage,
                                        editable: ScreenshotEditPayload? = nil,
                                        mode: MacScreenshotMode, source: MacScreenshotSource,
                                        pinAfterSave: Bool = false,
                                        pinContentFrame: CGRect? = nil) -> Bool {
        do {
            guard try store.addImage(image.data, type: image.type,
                                     sourceAppName: source.name,
                                     sourceAppBundleID: source.bundleID, screenshotOrigin: .cliphoook),
                  let newest = store.entries.first, newest.kind == .image else {
                statusMessage = "截图没有存入历史，请检查存储空间与图片大小限制。"
                return false
            }
            var editDataFailed = false
            if let editable {
                do {
                    try store.saveScreenshotEditData(base: editable.baseImageData,
                        document: editable.annotationData, for: newest)
                } catch { editDataFailed = true }
            }
            entries = store.rootEntries
            prepareOCRIfNeeded()
            refreshStorageSizes(force: false)
            if pinAfterSave {
                if pinImage(newest, at: pinContentFrame) {
                    activatePinnedImageAfterScreenshot = true
                    CopySoundPlayer.shared.playIfEnabled(.chime)
                    statusMessage = editDataFailed
                        ? "截图已钉住；编辑数据未保存，之后无法调整原标注。"
                        : "截图已保存并钉住"
                }
                // The image is already in history even if pinning fails.
                // Close the editor so retrying cannot create a duplicate card.
                return true
            }
            statusMessage = writeToPasteboard(newest, mode: .original)
                ? nil
                : "\(mode.title)已保存，但复制到剪贴板失败；可从图片卡片再次复制。"
            if editDataFailed { statusMessage = "图片已保存；编辑数据未保存，之后无法调整原标注。" }
            return true
        } catch {
            statusMessage = "保存\(mode.title)失败：\(error.localizedDescription)"
            return false
        }
    }

    func canAnnotateScreenshot(_ entry: ClipboardEntry) -> Bool {
        isImageAvailable(entry)
    }

    func saveImageToFile(_ entry: ClipboardEntry) {
        if entry.isScreenRecording, let access = store.filePreviewAccess(for: entry) {
            ScreenRecordingPreviewController.saveAs(access.url, retaining: access)
            return
        }
        guard NSApp.modalWindow == nil, entry.isImagePreviewable else { return }
        guard let current = store.entries.first(where: { $0.id == entry.id }) else {
            statusMessage = "这张图片已从历史记录移除。"
            return
        }
        let access = current.kind == .fileReference ? store.filePreviewAccess(for: current) : nil
        guard let source = store.imageURL(for: current) ?? access?.url else {
            statusMessage = "无法读取这张图片。"
            return
        }
        let name = current.fileName ?? ImageFileExport.suggestedName("图片", date: current.createdAt)
        let declaredType = (current.imagePasteboardType ?? current.fileType).flatMap(UTType.init)
        let extensionType = current.fileName.flatMap { UTType(filenameExtension: URL(fileURLWithPath: $0).pathExtension) }
            ?? UTType(filenameExtension: source.pathExtension)
        let knownType = [declaredType, extensionType].compactMap { $0 }.first { $0.conforms(to: .image) }
        let imageType = knownType ?? CGImageSourceCreateWithURL(source as CFURL, nil).flatMap {
            (CGImageSourceGetType($0) as String?).flatMap(UTType.init)
        }
        guard let imageType else {
            statusMessage = "无法确定图片格式。"
            return
        }
        let savePanel = ImageFileExport.makePanel(name: name, type: imageType)
        let response = panel.performModalInteraction { savePanel.runModal() }
        guard let destination = ImageFileExport.destination(in: savePanel, response: response) else { return }
        statusMessage = nil
        Task { [weak self, access] in
            defer { withExtendedLifetime(access) {} }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: source, options: .mappedIfSafe)
                    try ImageFileExport.write(data, to: destination)
                }.value
            } catch {
                self?.statusMessage = "保存图片失败：\(error.localizedDescription)"
            }
        }
    }

    func annotateScreenshot(_ entry: ClipboardEntry) {
        let data: Data?
        switch entry.kind {
        case .image:
            data = store.imageURL(for: entry).flatMap { try? Data(contentsOf: $0) }
        case .fileReference where entry.isImagePreviewable:
            data = store.withUsableFileURL(for: entry) { try? Data(contentsOf: $0) } ?? nil
        default:
            data = nil
        }
        guard let data else {
            statusMessage = "无法读取这张图片。"
            return
        }
        let present = { [weak self] in
            guard let self else { return }
            let editData = self.store.screenshotEditData(for: entry)
            guard self.imageEditor.open(
                data: data, editableBaseData: editData?.base,
                editableDocumentData: editData?.document,
                maximumBytes: self.store.maximumImageBytes,
                saveFailureMessage: { [weak self] in self?.statusMessage },
                onPin: { [weak self] result, editable in
                    self?.saveAnnotatedScreenshot(result, editable: editable,
                                                   source: entry, pinAfterSave: true) ?? false
                },
                onSave: { [weak self] result, editable in
                    self?.saveAnnotatedScreenshot(result, editable: editable, source: entry) ?? false
                }
            ) else {
                self.statusMessage = "无法打开截图标注编辑器。"
                return
            }
        }
        if panel.isVisible { panel.hide(restorePreviousApplication: false, completion: present) }
        else { present() }
    }

    private func saveAnnotatedScreenshot(_ image: MacScreenshotImage,
                                         editable: ScreenshotEditPayload?,
                                         source: ClipboardEntry, pinAfterSave: Bool = false) -> Bool {
        do {
            guard try store.addImage(
                image.data, type: image.type, sourceAppName: source.sourceAppName,
                sourceAppBundleID: source.sourceAppBundleID,
                screenshotOrigin: source.resolvedScreenshotOrigin ?? .ordinaryImage
            ), let newest = store.entries.first, newest.kind == .image else {
                statusMessage = "标注后的图片没有新增，请检查图片存储空间。"
                return false
            }
            var editDataFailed = false
            if let editable {
                do {
                    try store.saveScreenshotEditData(base: editable.baseImageData,
                        document: editable.annotationData, for: newest)
                } catch { editDataFailed = true }
            }
            entries = store.rootEntries
            prepareOCRIfNeeded()
            refreshStorageSizes(force: false)
            if pinAfterSave {
                if pinImage(newest) {
                    CopySoundPlayer.shared.playIfEnabled(.chime)
                    statusMessage = editDataFailed
                        ? "图片已钉住；编辑数据未保存，之后无法调整原标注。" : "标注图片已保存并钉住"
                }
                return true
            }
            statusMessage = writeToPasteboard(newest, mode: .original)
                ? nil
                : "标注截图已保存，但复制失败；可从新卡片再次复制。"
            if editDataFailed { statusMessage = "图片已保存；编辑数据未保存，之后无法调整原标注。" }
            return true
        } catch {
            statusMessage = "保存标注截图失败：\(error.localizedDescription)"
            return false
        }
    }

    func openSourceApplication(for entry: ClipboardEntry) {
        let bundleID = entry.sourceAppBundleID
        let name = entry.sourceAppName
        if name == "iPhone 截图" || name == "桌面"
            || name?.hasPrefix("Mac 截图") == true {
            statusMessage = "这张截图由 ClipHoook 保存，无法打开来源应用。"
            return
        }
        guard (bundleID?.isEmpty == false) || (name?.isEmpty == false) else {
            statusMessage = "这条记录没有可识别的来源应用。"
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolver = SourceApplicationResolver.shared
            let running = resolver.runningApplication(bundleID: bundleID, name: name)
            let appURL: URL?
            if let runningURL = running?.bundleURL {
                appURL = runningURL
            } else {
                appURL = await resolver.applicationURL(bundleID: bundleID, name: name)
            }
            guard let appURL else {
                self.statusMessage = "找不到来源应用“\(name ?? bundleID ?? "未知")”；应用可能已被卸载。"
                return
            }

            self.panel.hide(restorePreviousApplication: false) { [weak self] in
                Task { @MainActor [weak self] in
                    if let running, !running.isTerminated, running.activate(options: []) { return }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                        guard let error else { return }
                        Task { @MainActor [weak self] in
                            self?.statusMessage = "无法打开来源应用：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    func updatePanelLayout() {
        panel.updateLayoutIfVisible()
    }

    func activatePanelForImagePreview() {
        panel.activateForImagePreview()
    }

    @discardableResult
    func showDetailPreview(
        _ entry: ClipboardEntry,
        cardFrame: CGRect?,
        initiallyShowsOCR: Bool,
        initiallyShowsTools: Bool,
        onKeyDown: @escaping (NSEvent) -> Bool,
        onClose: @escaping () -> Void
    ) -> Bool {
        if entry.isImagePreviewable { prepareOCRIfNeeded(for: entry) }
        return panel.showDetail(entry, cardFrame: cardFrame,
                                initiallyShowsOCR: initiallyShowsOCR,
                                initiallyShowsTools: initiallyShowsTools,
                                onKeyDown: onKeyDown, onClose: onClose)
    }

    func updateDetailPreviewAnchor(for entryID: UUID, cardFrame: CGRect?) {
        panel.updateDetailAnchor(for: entryID, cardFrame: cardFrame)
    }

    func closeDetailPreview() {
        panel.hideDetail()
    }

    func updateAppearance(_ rawValue: String?) {
        let mode = AppAppearanceMode(rawValue: rawValue ?? "") ?? .system
        NSApp.appearance = mode.appearance
    }

    func beginShortcutRecording() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        hotKey.unregister()
        hotKeyRegistered = false
        quickSearchHotKey.unregister()
        quickSearchHotKeyRegistered = false
        for (_, hotKey) in screenshotHotKeys { hotKey.unregister() }
        registeredScreenshotHotKeys.removeAll()
    }

    func endShortcutRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        lastHotKeyAttempt = .distantPast
        lastQuickSearchHotKeyAttempt = .distantPast
        lastScreenshotHotKeyAttempt = .distantPast
        retryHotKeyIfNeeded()
        retryQuickSearchHotKeyIfNeeded()
        retryScreenshotHotKeysIfNeeded()
    }

    /// Keeps registration, collision checks, persistence and live panel input
    /// on the same mapping. A failed global registration leaves the old key.
    func setShortcut(_ shortcut: AppShortcut, for action: AppShortcutAction) -> String? {
        guard action.accepts(shortcut) else {
            if action.isAnnotationTool { return "请选择字母、数字或组合键；Esc、回车、方向键及常用编辑快捷键保留用于编辑。" }
            return action.requiresModifier
                ? "截图及全局快捷键需要 Command、Control 或 Option 与其他按键组合。"
                : "此按键不能用于面板操作；单键可选方向键、空格、Return 等功能键。"
        }
        if let conflict = AppShortcutAction.allCases.first(where: {
            $0 != action && self.shortcut(for: $0).hasSameKeys(as: shortcut)
        }) {
            return "\(shortcut.displayName) 已用于“\(conflict.title)”。"
        }
        if action == .quickSearch {
            let previous = self.shortcut(for: action)
            guard quickSearchHotKey.register(shortcut) else {
                if !isRecordingShortcut { quickSearchHotKeyRegistered = quickSearchHotKey.register(previous) }
                return "\(shortcut.displayName) 无法注册，可能已被系统或其他应用占用；原快捷键已保留。"
            }
            quickSearchHotKeyRegistered = true
        } else if action == .openPanel {
            let previous = openPanelShortcut
            guard hotKey.register(shortcut) else {
                if !isRecordingShortcut {
                    hotKeyRegistered = hotKey.register(previous)
                }
                return "\(shortcut.displayName) 无法注册，可能已被系统或其他应用占用；原快捷键已保留。"
            }
            hotKeyRegistered = true
            if statusMessage == hotKeyConflictMessageShown { statusMessage = nil }
            hotKeyConflictMessageShown = nil
        } else if let (_, captureKey) = screenshotHotKeys.first(where: { $0.0 == action }) {
            let previous = self.shortcut(for: action)
            guard captureKey.register(shortcut) else {
                if !isRecordingShortcut {
                    if captureKey.register(previous) { registeredScreenshotHotKeys.insert(action) }
                    else { registeredScreenshotHotKeys.remove(action) }
                }
                return "\(shortcut.displayName) 无法注册，可能已被系统或其他应用占用；原快捷键已保留。"
            }
            registeredScreenshotHotKeys.insert(action)
        }
        shortcuts[action] = shortcut
        screenRecorder.recordShortcut = self.shortcut(for: .recordScreen).displayName
        screenRecorder.pauseShortcut = self.shortcut(for: .pauseScreenRecording).displayName
        AppShortcutPreference.save(shortcut, for: action.preferenceKey)
        return nil
    }

    func setOpenPanelShortcut(_ shortcut: AppShortcut) -> String? {
        setShortcut(shortcut, for: .openPanel)
    }

    func setDeleteEntryShortcut(_ shortcut: AppShortcut) -> String? {
        setShortcut(shortcut, for: .deleteEntry)
    }

    func applyHistoryStorageSettings() {
        do {
            if try store.applyStoragePolicy() {
                entries = store.rootEntries
            }
            refreshStorageSizes()
        } catch {
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = "清理历史记录失败：\(error.localizedDescription)"
        }
    }

    func copy(_ entry: ClipboardEntry) {
        copy(entry, mode: defaultCopyMode(for: entry))
    }

    func copyPlainText(_ entry: ClipboardEntry) {
        guard Self.canUsePlainText([entry]) else {
            statusMessage = "这条记录没有可复制的纯文本。"
            return
        }
        copy(entry, mode: .plainText)
    }

    private func copy(_ entry: ClipboardEntry, mode: ClipboardPasteboardWriter.Mode) {
        guard writeToPasteboard(entry, mode: mode) else {
            if mode == .original && recoverUnavailableFilesForCopy([entry]) { return }
            statusMessage = entry.containsUnavailableImage
                ? (entry.kind == .group
                   ? "组内有图片未保存，无法完整复制；展开后可单独复制其他项目。"
                   : "这张图片未保存，无法复制。")
                : entry.kind == .fileReference
                ? "原文件和保存的副本都不可用；请重新选择文件。"
                : "复制失败，原始内容可能已不可用。"
            return
        }
        do {
            guard try store.recordCopy(of: entry.id) else {
                statusMessage = "已复制，但这条历史记录已不存在。"
                return
            }
            entries = store.rootEntries
        } catch {
            statusMessage = "已复制，但更新历史记录失败：\(error.localizedDescription)"
            return
        }
        statusMessage = Self.copiedMessage
        panel.hide()
    }

    func beginDrag(_ selection: [ClipboardEntry], reorderingIn scope: ClipboardCardOrderScope? = nil) -> ClipboardDragPayload? {
        guard !selection.isEmpty else { return nil }
        let ids = selection.map(\.id)
        let reorderScope = scope.flatMap { store.canReorderCards(ids, in: $0) ? $0 : nil }
        if var payload = ClipboardPasteboardWriter.dragPayload(expandedSelection(selection), from: store) {
            payload.sourceEntryIDs = ids
            payload.reorderScope = reorderScope
            return payload
        }
        // Favorites need only the history IDs, even if a source file is no
        // longer readable. Such a drag cannot export content to other apps.
        let item = NSPasteboardItem()
        _ = item.setString(selection.map { $0.id.uuidString }.joined(separator: ","),
                           forType: ClipboardInternalDrag.type)
        return ClipboardDragPayload(writers: [item], fileAccesses: [],
                                    sourceEntryIDs: ids, reorderScope: reorderScope, exportsContent: false)
    }

    @discardableResult
    func reorderCards(_ ids: [UUID], relativeTo target: UUID, after: Bool,
                      in scope: ClipboardCardOrderScope) -> Bool {
        do {
            guard try store.reorderCards(ids, relativeTo: target, after: after, in: scope) else { return false }
            entries = store.rootEntries
            statusMessage = nil
            return true
        } catch {
            statusMessage = "调整排序失败：\(error.localizedDescription)"
            return false
        }
    }

    func dragSessionMoved(to point: NSPoint) { panel.updateExternalDrag(at: point) }

    @discardableResult
    func moveFavorites(_ ids: [UUID], to categoryID: UUID) -> Bool {
        let chosen = Set(ids)
        let selection = store.entries.filter { chosen.contains($0.id) }
        guard !chosen.isEmpty, selection.count == chosen.count,
              let category = favoriteCategories.first(where: { $0.id == categoryID }) else { return false }
        if selection.allSatisfy({ $0.isFavorite && $0.favoriteCategoryID == categoryID }) {
            showToast("已在「\(category.name)」中")
            return true
        }
        do {
            try store.moveFavorites(chosen, to: categoryID)
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = nil
            showToast("已收藏到「\(category.name)」")
            return true
        } catch {
            statusMessage = "更新收藏失败：\(error.localizedDescription)"
            return false
        }
    }

    func dragSessionBegan() {
        panel.beginExternalDrag()
        stagingShelf?.internalDragBegan()
    }

    var isDraggingCard: Bool { panel.isCardDragActive }

    func cancelLocalCardDrag() -> Bool { panel.cancelLocalCardDrag() }

    func finishDrag(didDrop: Bool) {
        panel.finishExternalDrag(didDrop: didDrop)
    }

    func copySelection(_ selection: [ClipboardEntry], plainText: Bool = false) {
        guard selection.count > 1 else {
            if let entry = selection.first {
                plainText ? copyPlainText(entry) : copy(entry)
            }
            return
        }
        let members = expandedSelection(selection)
        if members.count == 1 {
            plainText ? copyPlainText(members[0]) : copy(members[0])
            return
        }
        if plainText && !Self.canUsePlainText(members) {
            statusMessage = "所选内容包含图片或文件，无法全部复制为纯文本。"
            return
        }
        guard writeToPasteboard(members, mode: plainText ? .plainText : .original) else {
            if !plainText && recoverUnavailableFilesForCopy(selection) { return }
            statusMessage = members.contains(where: { $0.kind == .unavailableImage })
                ? "所选内容包含未保存的微信图片，不能完整复制；可单独复制文字。"
                : "复制失败；选中的项目可能已不可用。"
            return
        }
        do {
            guard try store.recordBatchCopy(
                of: members.map(\.id),
                automaticallyGroup: false
            ) else {
                statusMessage = "已复制，但无法更新分组历史。"
                panel.hide()
                return
            }
            entries = store.rootEntries
            statusMessage = Self.copiedMessage
            panel.hide()
        } catch {
            entries = store.rootEntries
            statusMessage = "已复制，但更新分组历史失败：\(error.localizedDescription)"
        }
    }

    /// A sandboxed app cannot recover another app's private file location from
    /// its path alone. Let the user grant access to the file again, keep only
    /// the renewed bookmark, then complete the requested copy.
    private enum FileRecoveryAction { case copy, paste }

    private func recoverUnavailableFilesForCopy(
        _ selection: [ClipboardEntry], forceRelink: Bool = false,
        action: FileRecoveryAction = .copy, onRecovered: (([ClipboardEntry]) -> Void)? = nil
    ) -> Bool {
        guard !recoveringFileCopy else { return false }
        let unavailable = expandedSelection(selection).filter {
            $0.kind == .fileReference
                && (forceRelink || store.filePasteboardAccess(for: $0) == nil)
        }
        guard !unavailable.isEmpty else { return false }
        recoveringFileCopy = true
        let selectedIDs = selection.map(\.id)
        Task { @MainActor [self] in
            defer { recoveringFileCopy = false }
            let suggestions = Dictionary(uniqueKeysWithValues: unavailable.compactMap { entry -> (UUID, FilePreviewAccess)? in
                matchingAccessibleFinderFile(for: entry).map { (entry.id, $0) }
            })
            var useSuggestions = false
            if suggestions.count == unavailable.count {
                let alert = NSAlert()
                alert.messageText = "找到 \(unavailable.count) 个同名同大小的本机文件"
                alert.informativeText = "可改用访达记录中的文件位置并完成复制，不保存文件副本。请确认它们与原文件相同；也可以逐个手动选择。"
                alert.addButton(withTitle: "使用找到的文件")
                alert.addButton(withTitle: "逐个选择")
                alert.addButton(withTitle: "取消")
                switch panel.performModalInteraction({ alert.runModal() }) {
                case .alertFirstButtonReturn: useSuggestions = true
                case .alertSecondButtonReturn: break
                default:
                    statusMessage = "尚未复制；请重新选择原文件后再试。"
                    return
                }
            }
            for entry in unavailable {
                let chosen: URL
                if useSuggestions, let suggestion = suggestions[entry.id] {
                    chosen = suggestion.url
                } else {
                    let picker = NSOpenPanel()
                    picker.message = "ClipHoook 无法访问“\(entry.fileName ?? "原文件")”。请重新选择该文件以授权访问；只保存位置，不复制文件内容。"
                    picker.prompt = "重新关联"
                    picker.directoryURL = FileManager.default.urls(
                        for: .downloadsDirectory, in: .userDomainMask
                    ).first
                    picker.nameFieldStringValue = entry.fileName ?? ""
                    picker.canChooseDirectories = false
                    picker.allowsMultipleSelection = false
                    guard panel.performModalInteraction({ picker.runModal() }) == .OK,
                          let selected = picker.url else {
                        statusMessage = "尚未复制；请重新选择原文件后再试。"
                        return
                    }
                    chosen = selected
                }
                guard chosen.lastPathComponent == entry.fileName else {
                    statusMessage = "所选文件名与“\(entry.fileName ?? "原文件")”不一致；请重新选择。"
                    return
                }
                do {
                    guard let current = store.entries.first(where: { $0.id == entry.id }) else {
                        statusMessage = "这条文件记录已被删除，无法恢复。"
                        return
                    }
                    try store.relinkFileReference(current, to: chosen)
                    entries = store.rootEntries
                    refreshStorageSizes()
                } catch {
                    statusMessage = "恢复文件失败：\(error.localizedDescription)"
                    return
                }
            }
            let latest = selectedIDs.compactMap { id in
                store.rootEntries.first(where: { $0.id == id })
                    ?? store.entries.first(where: { $0.id == id })
            }
            guard latest.count == selectedIDs.count else {
                statusMessage = "文件已重新关联，但原选择发生变化；请重新选中后复制。"
                return
            }
            if let onRecovered { onRecovered(latest); return }
            switch action {
            case .copy: copySelection(latest)
            case .paste: pasteSelection(latest)
            }
        }
        return true
    }

    @discardableResult
    func groupSelection(_ selection: [ClipboardEntry]) -> UUID? {
        let members = expandedSelection(selection)
        guard members.count > 1 else {
            statusMessage = "请先多选至少两张卡片。"
            return nil
        }
        do {
            guard let groupID = try store.groupSelection(memberIDs: members.map(\.id)) else {
                statusMessage = "所选内容无法成组。"
                return nil
            }
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = nil
            showToast("已将 \(members.count) 项成组")
            return groupID
        } catch {
            entries = store.rootEntries
            statusMessage = "成组失败：\(error.localizedDescription)"
            return nil
        }
    }

    func ungroupSelection(_ selection: [ClipboardEntry]) {
        let groupIDs = selection.filter { $0.kind == .group }.map(\.id)
        guard !groupIDs.isEmpty else {
            statusMessage = "请先选中一个分组。"
            return
        }
        do {
            guard try store.ungroupSelection(groupIDs: groupIDs) else {
                statusMessage = "所选分组已不存在。"
                return
            }
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = nil
            showToast(groupIDs.count == 1 ? "已取消成组" : "已取消 \(groupIDs.count) 个分组")
        } catch {
            entries = store.rootEntries
            statusMessage = "取消成组失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func setShelfPinned(_ selection: [ClipboardEntry], pinned: Bool) -> Bool {
        do {
            let changed = try store.setShelfPinned(selection.map(\.id), pinned: pinned)
            guard changed > 0 else { return false }
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = nil
            if pinned {
                showToast(changed == 1 ? "已钉在面板" : "已钉住 \(changed) 张卡片")
            } else {
                showToast(changed == 1 ? "已取消面板钉住" : "已取消 \(changed) 张卡片的面板钉住")
            }
            return true
        } catch {
            statusMessage = "更新面板钉住失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func removeFavorites(_ selection: [ClipboardEntry]) -> Bool {
        guard !selection.isEmpty else { return false }
        if !selection.contains(where: \.isFavorite) {
            showToast("已取消收藏")
            return true
        }
        do {
            try store.setFavorites(Set(selection.map(\.id)), isFavorite: false)
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = nil
            showToast("已取消收藏")
            return true
        } catch {
            statusMessage = "更新收藏失败：\(error.localizedDescription)"
            return false
        }
    }

    func saveFavoriteCategory(name: String, tint: ClipboardFavoriteCategory.Tint,
                              icon: ClipboardFavoriteCategory.Icon, editing id: UUID?,
                              collecting ids: Set<UUID>) throws -> ClipboardFavoriteCategory {
        let category = try store.saveFavoriteCategory(name: name, tint: tint, icon: icon, editing: id, collecting: ids)
        favoriteCategories = store.favoriteCategories
        statusMessage = nil
        if ids.isEmpty {
            showToast(id == nil ? "已创建「\(category.name)」" : "已更新收藏分类")
        } else {
            entries = store.rootEntries
            refreshStorageSizes()
            showToast("已创建「\(category.name)」并收藏 \(ids.count) 张卡片")
        }
        return category
    }

    func confirmDeleteFavoriteCategory(_ category: ClipboardFavoriteCategory) -> Bool {
        let count = store.entries.count(where: { $0.favoriteCategoryID == category.id })
        let alert = NSAlert()
        alert.messageText = "删除「\(category.name)」？"
        if count > 0 { alert.informativeText = "其中的 \(count) 张卡片会留在历史中，继续保留星标。" }
        alert.addButton(withTitle: "删除分类")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn else { return false }
        do {
            try store.deleteFavoriteCategory(category.id)
            favoriteCategories = store.favoriteCategories
            entries = store.rootEntries
            statusMessage = nil
            showToast(count == 0 ? "已删除收藏分类" : "分类已删除，卡片已保留在历史")
            return true
        } catch {
            statusMessage = "删除分类失败：\(error.localizedDescription)"
            return false
        }
    }

    static func canUsePlainText(_ selection: [ClipboardEntry]) -> Bool {
        let members = selection.flatMap { $0.kind == .group ? $0.groupMembers : [$0] }
        return !members.isEmpty && members.allSatisfy { $0.kind == .text || $0.kind == .link }
    }

    func editText(_ entry: ClipboardEntry) {
        guard let current = store.entries.first(where: { $0.id == entry.id }),
              current.kind.isTextual, let text = current.text else {
            showToast("这张卡片的文字已不可用")
            return
        }
        panel.presentTextEditor(for: current, text: text) { [self] draft in
            guard let updated = try store.editText(draft, original: current) else { return }
            entries = store.rootEntries
            panel.refreshDetailLayout(for: updated)
            refreshStorageSizes()
            statusMessage = nil
            showToast("已保存编辑")
        }
    }

    func setScreenshotOrigin(_ origin: ClipboardScreenshotOrigin, for entry: ClipboardEntry) {
        do {
            guard try store.setScreenshotOrigin(origin, for: entry.id) else { return }
            entries = store.rootEntries
            statusMessage = nil
            showToast("已归入\(origin.label)")
        } catch {
            statusMessage = "更新截图分类失败：\(error.localizedDescription)"
        }
    }

    func setShelfHeaderPopoverVisible(_ visible: Bool) {
        panel.setShelfHeaderPopoverVisible(visible)
    }

    func paste(_ entry: ClipboardEntry) {
        paste(entry, mode: defaultCopyMode(for: entry))
    }

    func pasteFromQuickSearch(_ entry: ClipboardEntry, context: QuickSearchPasteContext) {
        paste([entry], mode: defaultCopyMode(for: entry), context: context)
    }

    func pastePlainText(_ entry: ClipboardEntry) {
        let members = entry.kind == .group ? entry.groupMembers : [entry]
        guard members.allSatisfy({ $0.kind == .text || $0.kind == .link }) else {
            statusMessage = "这条记录没有纯文本；请按 Return 粘贴原内容。"
            return
        }
        paste(entry, mode: .plainText)
    }

    func pasteSelection(_ selection: [ClipboardEntry], plainText: Bool = false) {
        guard selection.count > 1 else {
            if let entry = selection.first {
                plainText ? pastePlainText(entry) : paste(entry)
            }
            return
        }
        let members = expandedSelection(selection)
        if plainText && !members.allSatisfy({ $0.kind == .text || $0.kind == .link }) {
            statusMessage = "所选内容包含图片或文件，无法全部按纯文本粘贴。"
            return
        }
        paste(members, mode: plainText ? .plainText : .original)
    }

    private func expandedSelection(_ selection: [ClipboardEntry]) -> [ClipboardEntry] {
        var seen: Set<UUID> = []
        return selection.flatMap { $0.kind == .group ? $0.groupMembers : [$0] }
            .filter { seen.insert($0.id).inserted }
    }

    private func paste(_ entry: ClipboardEntry, mode: ClipboardPasteboardWriter.Mode) {
        paste([entry], mode: mode)
    }

    private func paste(_ selected: [ClipboardEntry], mode: ClipboardPasteboardWriter.Mode,
                       context: QuickSearchPasteContext? = nil) {
        cancelPasteHandoff()
        pasteFallbackPanel.dismiss()
        guard writeToPasteboard(selected, mode: mode) else {
            if mode == .original, let context,
               expandedSelection(selected).contains(where: { $0.kind == .fileReference }) {
                context.dismiss { [weak self] dismissed in
                    guard dismissed else { return }
                    _ = self?.recoverUnavailableFilesForCopy(selected, action: .paste, onRecovered: { [weak self] restored in
                        self?.paste(restored, mode: mode, context: context)
                    })
                }
                return
            }
            if mode == .original,
               recoverUnavailableFilesForCopy(selected, action: .paste) { return }
            statusMessage = selected.contains(where: \.containsUnavailableImage)
                ? "这次复制包含未保存的微信图片，不能完整粘贴；可单独粘贴文字。"
                : selected.contains(where: { $0.kind == .fileReference })
                ? "原文件和保存的副本都不可用；请重新选择文件。"
                : "粘贴失败，原始内容可能已不可用。"
            return
        }
        let clipboardChangeCount = NSPasteboard.general.changeCount
        let destination = context == nil ? panel.previousApplication : context?.application
        let destinationTarget = context == nil ? panel.previousTarget : context?.target
        switch PasteService.availability(requestPermission: true) {
        case .needsPermission:
            needsPastePermission = true
            showManualPasteMessage(Self.pastePermissionMessage, target: destination, context: context)
        case .ready:
            needsPastePermission = false
            guard let target = destination, !target.isTerminated else {
                showManualPasteMessage("已复制，请手动按 ⌘V；未找到原应用。", target: nil, context: context)
                return
            }
            guard let originalTarget = destinationTarget,
                  originalTarget.processIdentifier == target.processIdentifier else {
                showManualPasteMessage("已复制，请手动按 ⌘V；无法核对原输入位置。", target: target, context: context)
                return
            }
            hidePanelForPaste(context: context) { controller, handoffID in
                Task { @MainActor in
                    await controller.completePasteHandoff(
                        handoffID, to: target, originalTarget: originalTarget,
                        clipboardChangeCount: clipboardChangeCount
                    )
                }
            }
        }
    }

    private func hidePanelForPaste(context: QuickSearchPasteContext? = nil,
                                   _ completion: @escaping (AppController, UUID) -> Void) {
        let handoffID = pasteFocusHandoff.begin()
        let dismissed: (Bool) -> Void = { [weak self] dismissed in
            guard let self, self.pasteFocusHandoff.activeID == handoffID else { return }
            guard dismissed else {
                self.endPasteHandoff(handoffID)
                return
            }
            completion(self, handoffID)
        }
        if let context { context.dismiss(dismissed) }
        else { panel.hideForPaste(reclaimingPinKey: pinnedWindows?.hasKeyWindow == true, completion: dismissed) }
    }

    private func endPasteHandoff(_ id: UUID) {
        pasteFocusHandoff.end(id, at: NSEvent.mouseLocation)
    }

    private func cancelPasteHandoff() {
        if let id = pasteFocusHandoff.activeID { endPasteHandoff(id) }
    }

    private func completePasteHandoff(
        _ handoffID: UUID, to target: NSRunningApplication,
        originalTarget: PasteTargetSnapshot, clipboardChangeCount: Int
    ) async {
        defer { endPasteHandoff(handoffID) }
        guard pasteFocusHandoff.activeID == handoffID else { return }
        guard activatePasteTarget(target) else {
            reportPasteFallback("已复制，请手动按 ⌘V；无法切回原应用。")
            return
        }

        let targetPID = target.processIdentifier
        let usesForegroundKeyboard = PasteService.usesForegroundKeyboardStream(for: target.bundleIdentifier)
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(1500)
        while true {
            guard pasteFocusHandoff.activeID == handoffID else { return }
            let targetIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
            let ownWindowHasKeyboard = usesForegroundKeyboard && NSApp.keyWindow != nil
            if targetIsFrontmost && !ownWindowHasKeyboard && originalTarget.stillMatches() { break }
            guard clock.now < deadline else {
                if !targetIsFrontmost {
                    reportPasteFallback("已复制，请手动按 ⌘V；原应用未回到前台。")
                } else {
                    reportPasteFallback("已复制，请手动按 ⌘V；原输入位置未恢复或无法核对。")
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard NSPasteboard.general.changeCount == clipboardChangeCount else {
            reportPasteFallback("剪贴板内容已变化，已取消自动粘贴。")
            return
        }
        // Reading the target focus may involve an IPC round trip; check the
        // foreground again right before sending, especially for HID delivery.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
              PasteService.sendPasteShortcut(to: targetPID, bundleIdentifier: target.bundleIdentifier) else {
            reportPasteFallback("已复制，请手动按 ⌘V；自动粘贴未发出。")
            return
        }
        statusMessage = nil
        if usesForegroundKeyboard {
            // Keep the pin from taking focus while the queued HID key events
            // are being delivered to the foreground input field.
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func activatePasteTarget(_ target: NSRunningApplication) -> Bool {
        guard !target.isTerminated else { return false }
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if foregroundPID == target.processIdentifier { return true }
        if foregroundPID == NSRunningApplication.current.processIdentifier {
            NSApp.yieldActivation(to: target)
            return target.activate(from: .current, options: [])
        }
        return target.activate(options: [])
    }

    private func showManualPasteMessage(_ message: String, target: NSRunningApplication?,
                                        context: QuickSearchPasteContext? = nil) {
        hidePanelForPaste(context: context) { controller, handoffID in
            defer { controller.endPasteHandoff(handoffID) }
            if let target { _ = controller.activatePasteTarget(target) }
            controller.reportPasteFallback(message)
        }
    }

    private func reportPasteFallback(_ message: String) {
        statusMessage = message
        pasteFallbackPanel.show(
            message: message,
            onOpenSettings: needsPastePermission
                ? { [weak self] in self?.openPastePermissionSettings() }
                : nil
        )
    }

    func openPastePermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else {
            statusMessage = "无法打开权限页面。请在系统设置的隐私与安全性中找到本应用。"
            return
        }
    }

    func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "这会删除本机保存的全部历史记录（包括收藏和面板钉住的卡片）及其贴图副本，无法撤销。原文件和系统剪贴板会保留。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn {
            var failure: Error?
            do { try store.clear() }
            catch { failure = error }
            // The history database may already be empty if removing one of its
            // payload files failed. In that case the explicit clear still
            // removes the corresponding independent pin snapshots.
            if store.entries.isEmpty {
                do { try pinnedWindows?.unpinAll() }
                catch { failure = failure ?? error }
            }
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = failure.map { "清空未完成：\($0.localizedDescription)" }
                ?? "历史记录和对应贴图已清空"
        }
    }

    func confirmDelete(_ entry: ClipboardEntry) {
        let alert = NSAlert()
        alert.messageText = "删除这条历史记录？"
        alert.informativeText = "只删除本机保存的这条记录及其副本；若已钉在桌面，对应贴图也会取消。不会删除原文件或清空系统剪贴板。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        var failure: Error?
        do { try store.delete(entry) }
        catch { failure = error }
        if !store.entries.contains(where: { $0.id == entry.id }) {
            if let pin = pinnedStore?.record(for: entry.id) {
                do { try pinnedWindows?.unpin(pin.id) }
                catch { failure = failure ?? error }
            }
        }
        entries = store.rootEntries
        refreshStorageSizes()
        if let failure {
            statusMessage = "删除未完成：\(failure.localizedDescription)"
        } else {
            statusMessage = nil
            showToast("已删除")
        }
    }

    private func showToast(_ message: String, duration: Duration = .seconds(2)) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
            self?.toastDismissTask = nil
        }
    }

    private func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastMessage = nil
    }

    private func showFirstPinnedImageGestureHint(for pinID: UUID) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: PinnedImageDiscovery.gestureTipShownKey) else { return }
        pinnedGestureHintTask?.cancel()
        pinnedGestureHintTask = Task { @MainActor [weak self] in
            // Wait for the source preview's exit animation. The hint belongs
            // to the pinned image, and may be shown even after the shelf hides.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self,
                  self.pinnedWindows?.showGestureHint(for: pinID) == true else { return }
            defaults.set(true, forKey: PinnedImageDiscovery.gestureTipShownKey)
            self.pinnedGestureHintTask = nil
        }
    }

    func addExcludedApplication() {
        SettingsWindowController.shared.chooseExcludedApplication { [weak self] url in
            guard let self, let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            self.excludedApplications.removeAll { $0.bundleIdentifier == bundleID }
            self.excludedApplications.append(ExcludedApplication(bundleIdentifier: bundleID, name: name))
            self.excludedApplications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            RecordingExclusionPolicy.save(self.excludedApplications, in: .standard)
        }
    }

    func removeExcludedApplication(_ application: ExcludedApplication) {
        excludedApplications.removeAll { $0.id == application.id }
        RecordingExclusionPolicy.save(excludedApplications, in: .standard)
    }

    func resetExcludedApplications() {
        excludedApplications = []
        RecordingExclusionPolicy.save([], in: .standard)
        statusMessage = nil
    }

    func confirmRemoveMigrationBackup() {
        let alert = NSAlert()
        alert.messageText = "删除旧历史备份？"
        alert.informativeText = "这份备份用于迁移后的手动回退。删除后无法用它恢复迁移前的历史记录。"
        alert.addButton(withTitle: "删除备份")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        do {
            try store.removeMigrationBackup()
            refreshStorageSizes()
        } catch {
            statusMessage = "删除备份失败：\(error.localizedDescription)"
        }
    }

    func confirmRemoveRecoveryFiles() {
        let alert = NSAlert()
        alert.messageText = "删除未关联的恢复文件？"
        alert.informativeText = "这些文件不在当前历史列表中。删除后无法再手动找回它们。"
        alert.addButton(withTitle: "删除恢复文件")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        do {
            try store.removeRecoveryFiles()
            refreshStorageSizes()
        } catch {
            statusMessage = "删除恢复文件失败：\(error.localizedDescription)"
        }
    }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        store.imageURL(for: entry)
    }

    /// Include image-file references and grouped members as well as ordinary
    /// bitmap history entries. The annotation picker never changes the shelf
    /// selection or the user's system pasteboard.
    var annotationImageEntries: [ClipboardEntry] {
        store.entries.filter(\.isImagePreviewable)
    }

    func annotationImageData(for entry: ClipboardEntry) -> Data? {
        guard let current = store.entries.first(where: { $0.id == entry.id }),
              current.isImagePreviewable else { return nil }
        func read(_ url: URL) -> Data? {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 64 * 1024 * 1024 else { return nil }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        if current.kind == .image { return store.imageURL(for: current).flatMap(read) }
        return store.withUsableFileURL(for: current, read) ?? nil
    }

    func annotationImageThumbnail(for entry: ClipboardEntry) async -> NSImage? {
        let data = store.thumbnailURL(for: entry).flatMap { try? Data(contentsOf: $0) }
            ?? annotationImageData(for: entry)
        guard let data else { return nil }
        let bitmap = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary)
        }.value
        guard !Task.isCancelled else { return nil }
        if let bitmap { return NSImage(cgImage: bitmap, size: CGSize(width: bitmap.width, height: bitmap.height)) }
        // AppKit also accepts SVG when ImageIO has no raster representation.
        return NSImage(data: data)
    }

    private func isImageAvailable(_ entry: ClipboardEntry) -> Bool {
        guard entry.isImagePreviewable else { return false }
        if entry.kind == .image { return store.imageURL(for: entry) != nil }
        return store.fileReferenceIsAvailable(entry)
    }

    func canRecognizeImage(_ entry: ClipboardEntry) -> Bool {
        isImageAvailable(entry)
    }

    func recognizeImageText(_ entry: ClipboardEntry) {
        startImageRecognition(for: entry.id, forSearch: false)
    }

    func setImageTextSearchScope(_ scope: ClipboardImageSearchScope?) {
        guard imageTextSearchScope != scope else { return }
        imageTextSearchScope = scope
        guard let scope else {
            attemptedImageSearchIDs.removeAll()
            isSearchingImageText = false
            return
        }
        if imageTextSearchTask != nil {
            isSearchingImageText = !pendingImageSearchIDs(in: scope, includeInProgress: true).isEmpty
        }
        resumeImageTextSearchIfNeeded()
    }

    func resumeImageTextSearchIfNeeded() {
        guard imageTextSearchTask == nil, let scope = imageTextSearchScope else { return }
        let candidates = pendingImageSearchIDs(in: scope)
        guard !candidates.isEmpty else { return }
        isSearchingImageText = true
        imageTextSearchTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.recognizeImagesForSearch(scope: scope, candidates: candidates)
        }
    }

    private func pendingImageSearchIDs(in scope: ClipboardImageSearchScope,
                                       includeInProgress: Bool = false) -> [UUID] {
        ClipboardFilterInventory.unrecognizedImages(in: entries, scope: scope).compactMap { entry in
            if imageOCRInProgress.contains(entry.id) { return includeInProgress ? entry.id : nil }
            return attemptedImageSearchIDs.contains(entry.id) ? nil : entry.id
        }
    }

    private func recognizeImagesForSearch(scope: ClipboardImageSearchScope, candidates: [UUID]) async {
        var scheduledScope = scope
        var queue = candidates[...]
        defer {
            publishImageSearchResults()
            imageTextSearchTask = nil
            isSearchingImageText = false
        }
        while let activeScope = imageTextSearchScope {
            if activeScope != scheduledScope || queue.isEmpty {
                scheduledScope = activeScope
                queue = pendingImageSearchIDs(in: activeScope)[...]
            }
            guard let id = queue.popFirst() else { break }
            guard attemptedImageSearchIDs.insert(id).inserted else { continue }
            if let recognition = startImageRecognition(for: id, forSearch: true) {
                if !isSearchingImageText { isSearchingImageText = true }
                // Let the current image finish if the scope changes. The next
                // iteration reads the new scope before starting more work.
                await recognition.value
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    private func scheduleImageSearchPublication() {
        guard imageSearchPublicationTask == nil else { return }
        imageSearchPublicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            self?.publishImageSearchResults()
        }
    }

    private func publishImageSearchResults() {
        guard let publication = imageSearchPublicationTask else { return }
        publication.cancel()
        imageSearchPublicationTask = nil
        entries = store.rootEntries
        refreshStorageSizes(force: false)
    }

    @discardableResult
    private func startImageRecognition(for id: UUID, forSearch: Bool) -> Task<Void, Never>? {
        guard !imageOCRInProgress.contains(id),
              let current = store.entries.first(where: { $0.id == id }), current.isImagePreviewable,
              !forSearch || current.ocrText == nil else { return nil }
        let access = current.kind == .fileReference ? store.filePreviewAccess(for: current) : nil
        guard let url = current.kind == .image ? store.imageURL(for: current) : access?.url,
              let signature = store.ocrSourceSignature(for: current) else {
            if !forSearch { imageOCRErrors[id] = ImageOCRError.unreadableImage.localizedDescription }
            return nil
        }
        if imageOCRErrors[id] != nil { imageOCRErrors[id] = nil }
        imageOCRInProgress.insert(id)
        let priority: TaskPriority = forSearch ? .utility : .userInitiated
        return Task(priority: priority) { @MainActor [weak self, access] in
            guard let self else { return }
            defer {
                withExtendedLifetime(access) {}
                self.imageOCRInProgress.remove(id)
            }
            do {
                let text = try await ImageOCRService.recognize(at: url, priority: priority)
                try self.store.saveOCRText(text, for: current,
                                           expectedSourceSignature: signature)
                if forSearch {
                    self.scheduleImageSearchPublication()
                } else {
                    self.entries = self.store.rootEntries
                    self.refreshStorageSizes()
                    if text.isEmpty { self.showToast("没有识别到文字") }
                }
            } catch {
                let message = error.localizedDescription
                self.imageOCRErrors[id] = message
                if !forSearch { self.statusMessage = "识别文字失败：\(message)" }
            }
        }
    }

    private func prepareOCRIfNeeded(for entry: ClipboardEntry? = nil) {
        guard !didStartOCRPreparation,
              (entry?.isImagePreviewable == true || entries.contains {
                  $0.isImagePreviewable || $0.groupMembers.contains(where: \.isImagePreviewable)
              }) else { return }
        didStartOCRPreparation = true
        ImageOCRService.prepareInBackground()
    }

    func copyRecognizedText(_ text: String) {
        _ = copyPreviewText(text, message: "已复制识别文字", recordInHistory: true)
    }

    @discardableResult
    func copyScreenshotRecognizedText(_ text: String) -> Bool {
        copyPreviewText(text, message: "已复制识别文字", recordInHistory: true)
    }

    func copySelectedPreviewText(_ text: String) {
        _ = copyPreviewText(text, message: "已复制选中文字")
    }

    @discardableResult
    func copyTranslatedText(_ text: String) -> Bool {
        copyPreviewText(text, message: "已复制译文", recordInHistory: true)
    }

    @discardableResult
    func copyProcessedText(_ text: String) -> Bool {
        copyPreviewText(text, message: "已复制处理结果")
    }

    private func copyPreviewText(_ text: String, message: String,
                                 recordInHistory: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            statusMessage = "复制文字失败。"
            return false
        }
        clipboardChanges.markOwnWrite(changeCount: board.changeCount)
        var feedback = message
        if recordInHistory && !isPaused {
            do {
                // Derived text is new clipboard content. Record it explicitly;
                // the own-write marker still prevents a second capture/sound.
                if try store.addText(text, sourceAppName: "ClipHoook",
                                     sourceAppBundleID: Bundle.main.bundleIdentifier) {
                    entries = store.rootEntries
                    refreshStorageSizes(force: false)
                    feedback += "，已加入历史"
                } else {
                    feedback += "；文字过长，未加入历史"
                }
            } catch {
                statusMessage = "已复制，但保存文字历史失败：\(error.localizedDescription)"
                feedback += "，但保存历史失败"
            }
        }
        playCopyFeedback()
        showToast(feedback)
        return true
    }

    private func playCopyFeedback() {
        menuBarCopyAnimation.play()
        CopySoundPlayer.shared.playIfEnabled()
    }

    func canPinImage(_ entry: ClipboardEntry) -> Bool {
        isImageAvailable(entry)
    }

    func isPinnedImage(_ entry: ClipboardEntry) -> Bool {
        pinnedStore?.record(for: entry.id) != nil
    }

    /// Returns true only when this action has just pinned an image, so callers
    /// can dismiss an open preview while leaving the shelf itself visible.
    @discardableResult
    func togglePinImage(_ entry: ClipboardEntry) -> Bool {
        guard entry.isImagePreviewable || isPinnedImage(entry) else {
            statusMessage = "请选择图片卡片，或可预览的图片文件。"
            return false
        }
        if isPinnedImage(entry) {
            unpinImage(entry)
            return false
        }
        return pinImage(entry)
    }

    @discardableResult
    func pinImage(_ entry: ClipboardEntry, at contentFrame: CGRect? = nil) -> Bool {
        guard canPinImage(entry), let pinnedStore, let pinnedWindows else {
            statusMessage = PinnedImageError.imageUnavailable.localizedDescription
            return false
        }
        do {
            let title = entry.kind == .image
                ? (entry.sourceAppName == "iPhone 截图" ? "iPhone 截图" : "图片")
                : entry.title
            let record: PinnedImageRecord
            if entry.kind == .image {
                guard let url = store.imageURL(for: entry) else { throw PinnedImageError.imageUnavailable }
                record = try pinnedStore.add(sourceEntryID: entry.id, sourceURL: url,
                                             title: title,
                                             initialContentFrame: contentFrame)
            } else {
                guard let result = store.withUsableFileURL(for: entry, { url in
                    Result { try pinnedStore.add(sourceEntryID: entry.id, sourceURL: url, title: title) }
                }) else { throw PinnedImageError.imageUnavailable }
                record = try result.get()
            }
            pinnedImageCount = pinnedStore.count
            pinnedStorageBytes = pinnedStore.storageBytes
            try pinnedWindows.show(record)
            SettingsWindowController.shared.parkForPinnedImageInteraction()
            panel.activateForPinnedImageInteraction()
            showFirstPinnedImageGestureHint(for: record.id)
            return true
        } catch {
            statusMessage = "钉住图片失败：\(error.localizedDescription)"
            return false
        }
    }

    func unpinImage(_ entry: ClipboardEntry) {
        guard let record = pinnedStore?.record(for: entry.id), let pinnedWindows else { return }
        do { try pinnedWindows.unpin(record.id) }
        catch { statusMessage = "取消钉住失败：\(error.localizedDescription)" }
    }

    private func copyPinnedImage(_ record: PinnedImageRecord) {
        let entry = store.entries.first { $0.id == record.sourceEntryID }
        let board = NSPasteboard.general
        guard let snapshot = pinnedStore?.imageURL(for: record),
              ClipboardPasteboardWriter.writeImageSnapshot(
                  at: snapshot, origin: entry?.resolvedScreenshotOrigin, to: board
              ) else {
            statusMessage = "未能复制贴图，保存的图片可能已不可用。"
            return
        }
        clipboardChanges.markOwnWrite(changeCount: board.changeCount)
        playCopyFeedback()
        do {
            // The pin is usable even if the associated history was pruned.
            if try store.recordCopy(of: record.sourceEntryID) { entries = store.rootEntries }
            statusMessage = Self.copiedMessage
        } catch {
            statusMessage = "已复制图片，但更新历史记录失败：\(error.localizedDescription)"
        }
    }

    func showPinnedImages() {
        pinnedWindows?.showAll()
    }

    func confirmUnpinAllImages() {
        guard pinnedImageCount > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "取消全部贴图？"
        alert.informativeText = "这会关闭所有贴图窗口并删除贴图副本；剪贴板历史记录仍保留。"
        alert.addButton(withTitle: "取消全部钉住")
        alert.addButton(withTitle: "返回")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try pinnedWindows?.unpinAll() }
        catch { statusMessage = "取消贴图失败：\(error.localizedDescription)" }
    }

    func flushPinnedImageFrames() {
        pinnedWindows?.flushFrames()
    }

    func openStagingShelf() { stagingShelf?.open() }
    func updateStagingShelfPreferences() { stagingShelf?.applyPreferences() }
    func clearStagingShelf() { stagingShelf?.confirmClear() }

    func saveStagingImageToFile(_ payload: StagingShelfPreviewPayload) {
        guard NSApp.modalWindow == nil, payload.previewEntry.kind == .image,
              case .file(let source) = payload.content,
              let type = UTType(filenameExtension: source.pathExtension) else { return }
        let finish = stagingShelf?.beginContentInteraction()
        defer { finish?() }
        let chooser = ImageFileExport.makePanel(name: payload.name, type: type)
        let response = panel.performModalInteraction { chooser.runModal() }
        guard let destination = ImageFileExport.destination(in: chooser, response: response) else { return }
        Task { [weak self, access = payload.access] in
            defer { withExtendedLifetime(access) {} }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ImageFileExport.write(Data(contentsOf: source, options: .mappedIfSafe), to: destination)
                }.value
            } catch { self?.statusMessage = "保存图片失败：\(error.localizedDescription)" }
        }
    }

    func annotateStagingImage(_ payload: StagingShelfPreviewPayload) {
        guard !imageEditor.isPresenting, NSApp.modalWindow == nil,
              payload.previewEntry.kind == .image, case .file(let url) = payload.content else { return }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= store.maximumImageBytes, let data = try? Data(contentsOf: url) else {
            statusMessage = "图片无法读取或超过标注大小限制。"; return
        }
        stagingShelf?.closePreview()
        guard imageEditor.open(data: data, maximumBytes: store.maximumImageBytes,
            saveFailureMessage: { [weak self] in self?.statusMessage },
            onPin: { [weak self] result, editable in
                self?.saveAnnotatedScreenshot(result, editable: editable, source: payload.previewEntry, pinAfterSave: true) ?? false
            },
            onSave: { [weak self] result, editable in
                self?.saveAnnotatedScreenshot(result, editable: editable, source: payload.previewEntry) ?? false
            }) else { statusMessage = "无法打开图片标注编辑器。"; return }
    }

    @discardableResult
    func pinStagingImage(_ payload: StagingShelfPreviewPayload) -> Bool {
        guard payload.previewEntry.kind == .image, case .file(let url) = payload.content,
              let pinnedStore, let pinnedWindows else { return false }
        do {
            let record = try pinnedStore.add(sourceEntryID: payload.id, sourceURL: url, title: payload.name)
            pinnedImageCount = pinnedStore.count
            pinnedStorageBytes = pinnedStore.storageBytes
            try pinnedWindows.show(record)
            SettingsWindowController.shared.parkForPinnedImageInteraction()
            stagingShelf?.closePreview()
            panel.activateForPinnedImageInteraction()
            showFirstPinnedImageGestureHint(for: record.id)
            return true
        } catch { statusMessage = "钉住图片失败：\(error.localizedDescription)"; return false }
    }

    func editStagingText(_ payload: StagingShelfPreviewPayload) {
        guard case .text(let text) = payload.content, let stagingShelf else { return }
        let finish = stagingShelf.beginContentInteraction()
        let opened = panel.presentTextEditor(for: payload.previewEntry, text: text, onClose: finish) { [weak self] draft in
            guard let self, let shelf = self.stagingShelf else { throw StagingShelfError.unavailable }
            try shelf.store.editText(id: payload.id, text: draft)
        }
        if !opened { finish() }
    }

    private func configureStagingShelf() {
        let stagingStore = StagingShelfStore(directory: store.stagingShelfDirectory)
        stagingStore.resolveHistoryAccess = { [weak self] url in
            guard let self, let entry = self.store.entries.first(where: {
                $0.kind == .fileReference && $0.filePath == url.path
            }) else { return nil }
            return self.store.filePasteboardAccess(for: entry)
        }
        stagingStore.isHistoryImage = { [weak self] url in
            self?.store.entries.contains(where: {
                $0.kind == .image && self?.store.imageURL(for: $0)?.standardizedFileURL == url.standardizedFileURL
            }) == true
        }
        let controller = StagingShelfController(store: stagingStore)
        controller.makePreviewContent = { [weak self, weak controller] session, tail, scale in
            guard let self else { return NSView() }
            return StagingDetailHostingView(rootView: StagingDetailPreviewView(
                model: self, session: session, tail: tail, backingScale: scale,
                onCopy: { controller?.copyItem(session.entry.id) },
                onRemove: { controller?.remove([session.entry.id]) },
                onKeyDown: { controller?.handleKey($0) ?? false },
                onClose: { controller?.closePreview() }
            ))
        }
        controller.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.screenshotCapture.isActive || self.screenshotEditor.isPresenting ||
                self.imageEditor.isPresenting ||
                self.longScreenshot.isPresenting || NSApp.modalWindow != nil || self.isRecordingShortcut
        }
        controller.onChange = { [weak self, weak stagingStore] in
            self?.stagingItemCount = stagingStore?.items.count ?? 0
        }
        stagingShelf = controller
        stagingItemCount = stagingStore.items.count
        controller.start()
    }

    private func configurePinnedImages() {
        do {
            let pinnedStore = try PinnedImageStore(directory: store.pinnedImagesDirectory)
            self.pinnedStore = pinnedStore
            let manager = PinnedImageWindowManager(
                store: pinnedStore,
                pasteFocusHandoff: pasteFocusHandoff,
                onChange: { [weak self] in
                    self?.pinnedImageCount = pinnedStore.count
                    self?.pinnedStorageBytes = pinnedStore.storageBytes
                },
                onError: { [weak self] message in self?.statusMessage = message },
                onCopyImage: { [weak self] record in self?.copyPinnedImage(record) },
                onDismissShelf: { [weak self] in
                    guard let self, self.panel.isVisible else { return false }
                    self.panel.hide(restorePreviousApplication: false)
                    return true
                }
            )
            pinnedWindows = manager
            pinnedImageCount = pinnedStore.count
            pinnedStorageBytes = pinnedStore.storageBytes
            manager.restore()
        } catch {
            statusMessage = "贴图记录无法加载：\(error.localizedDescription)"
        }
    }

    func imagePreviewPixelSize(for entry: ClipboardEntry) -> CGSize? {
        guard entry.isImagePreviewable else { return nil }
        if entry.kind == .image {
            guard let url = store.imageURL(for: entry) else { return nil }
            return ImagePixelDimensions.pixelSize(at: url)
                ?? NSImage(contentsOf: url).flatMap(ImagePixelDimensions.pixelSize(of:))
        }
        return store.withUsableFileURL(for: entry) { url in
            ImagePixelDimensions.pixelSize(at: url)
                ?? NSImage(contentsOf: url).flatMap(ImagePixelDimensions.pixelSize(of:))
        } ?? nil
    }

    func thumbnailURL(for entry: ClipboardEntry) -> URL? {
        store.thumbnailURL(for: entry)
    }

    func fileReferencePreviewImage(for entry: ClipboardEntry) async -> NSImage? {
        guard entry.kind == .fileReference else { return nil }
        let key = "\(entry.id.uuidString)-\(entry.fileCopyName ?? "original")" as NSString
        if let cached = filePreviewCache.object(forKey: key) { return cached }
        let data = store.withUsableFileURL(for: entry) { url -> Data? in
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return data
        } ?? nil
        guard let data else { return nil }
        // Decode the original pixels only after opening the detail view. The
        // card keeps using its small thumbnail, while 100% zoom stays sharp.
        let bitmap = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else { return nil as CGImage? }
            return CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }.value
        guard !Task.isCancelled, let bitmap else { return nil }
        let image = NSImage(
            cgImage: bitmap,
            size: NSSize(width: bitmap.width, height: bitmap.height)
        )
        let decodedBytes = bitmap.bytesPerRow * bitmap.height
        if decodedBytes <= 128 * 1_024 * 1_024 {
            filePreviewCache.setObject(image, forKey: key, cost: decodedBytes)
        }
        return image
    }

    func richTextSourceFiles(for entry: ClipboardEntry) -> RichTextSourceFiles {
        store.richTextSourceFiles(for: entry)
    }

    func fileHasSavedCopy(_ entry: ClipboardEntry) -> Bool {
        store.fileHasSavedCopy(entry)
    }

    func savedCopyDisplayName(for entry: ClipboardEntry) -> String? {
        store.savedCopyDisplayName(for: entry)
    }

    func fileReferenceIsAvailable(_ entry: ClipboardEntry) -> Bool {
        store.fileReferenceIsAvailable(entry)
    }

    func fileReferenceCanBeRepublished(_ entry: ClipboardEntry) -> Bool {
        store.filePasteboardAccess(for: entry) != nil
    }

    func originalFileReferenceIsAvailable(_ entry: ClipboardEntry) -> Bool {
        store.originalFileIsAvailable(entry)
    }

    func canAuthorizeWeChatFolder(_ entry: ClipboardEntry) -> Bool {
        store.suggestedWeChatFolder(for: entry) != nil
    }

    func filePreviewAccess(for entry: ClipboardEntry) -> FilePreviewAccess? {
        store.filePreviewAccess(for: entry)
    }

    func relinkUnavailableFile(_ entry: ClipboardEntry) {
        guard entry.kind == .fileReference else { return }
        if !recoverUnavailableFilesForCopy([entry], forceRelink: true) {
            statusMessage = "当前无法重新关联这条文件记录。"
        }
    }

    func authorizeWeChatFolder(for entry: ClipboardEntry) {
        guard let suggested = store.suggestedWeChatFolder(for: entry) else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = suggested.deletingLastPathComponent()
        picker.message = "请选择“\(suggested.lastPathComponent)”文件夹。授权后，ClipHoook 仅在使用对应文件卡片时读取文件，不扫描聊天记录，也不保存文件副本。"
        picker.prompt = "授权文件夹"
        guard panel.performModalInteraction({ picker.runModal() }) == .OK,
              let selected = picker.url else { return }
        do {
            try store.authorizeWeChatFolder(selected, for: entry)
            entries = store.rootEntries
            statusMessage = nil
            showToast("微信文件夹已授权")
        } catch {
            statusMessage = selected.standardizedFileURL.path == suggested.standardizedFileURL.path
                ? "文件夹已选中，但这份原文件仍无法读取。请确认微信文件仍存在。"
                : "请选择“\(suggested.lastPathComponent)”文件夹，才能授权这条微信文件。"
        }
    }

    private func matchingAccessibleFinderFile(for entry: ClipboardEntry) -> FilePreviewAccess? {
        guard let candidate = store.entries.first(where: {
            $0.kind == .fileReference && $0.id != entry.id
                && $0.fileName == entry.fileName
                && $0.byteCount == entry.byteCount
                && $0.fileCopyName == nil
                && $0.filePath != entry.filePath
                && $0.sourceAppName == "访达"
        }) else { return nil }
        return store.filePreviewAccess(for: candidate)
    }

    @discardableResult
    func revealOriginalFile(_ entry: ClipboardEntry) -> Bool {
        guard store.withOriginalFileURL(for: entry, { url in
            panel.hide(restorePreviousApplication: false)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }) == true else {
            statusMessage = "原文件已移动、删除或无法访问；无法在访达中显示。"
            return false
        }
        return true
    }

    func saveFileCopy(_ entry: ClipboardEntry) {
        guard entry.kind == .fileReference else { return }
        let isUpdating = store.fileHasSavedCopy(entry)
        let alert = NSAlert()
        alert.messageText = isUpdating ? "更新已保存的文件副本？" : "保存这份文件的副本？"
        alert.informativeText = isUpdating
            ? "会用原文件的当前内容替换 ClipHoook 中已有的副本。"
            : "会把文件复制到 ClipHoook 的本地存储，占用相应空间；原文件移动后仍可复制或粘贴。"
        alert.alertStyle = isUpdating ? .warning : .informational
        alert.addButton(withTitle: isUpdating ? "更新副本" : "保存副本")
        alert.addButton(withTitle: "取消")
        guard panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        var replacement: URL?
        if !store.originalFileIsAvailable(entry) {
            let picker = NSOpenPanel()
            picker.message = "原文件不可用。请选择要保存副本的原文件。"
            picker.canChooseDirectories = false
            picker.allowsMultipleSelection = false
            guard panel.performModalInteraction({ picker.runModal() }) == .OK,
                  let selected = picker.url else { return }
            replacement = selected
        }
        Task { @MainActor [self] in
            do {
                try await store.saveFileCopy(for: entry, using: replacement)
                entries = store.rootEntries
                refreshStorageSizes()
                statusMessage = nil
                showToast(isUpdating ? "文件副本已更新" : "文件副本已保存")
                if let updated = entries.first(where: { $0.id == entry.id }) {
                    store.requestThumbnail(for: updated) { [weak self] in
                        self?.entries = self?.store.rootEntries ?? []
                    }
                }
            } catch {
                statusMessage = "保存文件副本失败：\(error.localizedDescription)"
            }
        }
    }

    func removeSavedFileCopy(_ entry: ClipboardEntry) {
        guard entry.kind == .fileReference, store.fileHasSavedCopy(entry) else { return }
        var current = store.entries.first(where: { $0.id == entry.id }) ?? entry
        if !store.originalFileCanBeReused(current) {
            let suggestion = matchingAccessibleFinderFile(for: current)
            let alert = NSAlert()
            alert.messageText = "需要先关联可访问的原文件"
            alert.informativeText = suggestion == nil
                ? "原文件当前无法访问。请选择同一文件；确认后只更新文件位置，并移除 ClipHoook 保存的副本。"
                : "找到访达记录中同名同大小的文件。请确认它是同一文件；确认后只更新文件位置，并移除 ClipHoook 保存的副本。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: suggestion == nil ? "选择文件并移除" : "使用找到的文件并移除")
            if suggestion != nil { alert.addButton(withTitle: "手动选择") }
            alert.addButton(withTitle: "取消")
            let choice = panel.performModalInteraction { alert.runModal() }
            guard choice == .alertFirstButtonReturn
                    || (suggestion != nil && choice == .alertSecondButtonReturn) else { return }
            let chosen: URL
            if choice == .alertFirstButtonReturn, let suggestion {
                chosen = suggestion.url
            } else {
                let picker = NSOpenPanel()
                picker.message = "请选择与“\(current.fileName ?? "原文件")”相同的文件；不会保存副本。"
                picker.prompt = "选择原文件"
                picker.canChooseDirectories = false
                picker.allowsMultipleSelection = false
                picker.nameFieldStringValue = current.fileName ?? ""
                guard panel.performModalInteraction({ picker.runModal() }) == .OK,
                      let selected = picker.url else { return }
                chosen = selected
            }
            let size = try? chosen.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard chosen.lastPathComponent == current.fileName,
                  current.byteCount <= 0 || size == current.byteCount else {
                statusMessage = "所选文件的名称或大小与记录不符；本地副本仍保留。"
                return
            }
            do {
                try store.relinkFileReference(current, to: chosen)
                guard let updated = store.entries.first(where: { $0.id == entry.id }),
                      store.originalFileCanBeReused(updated) else {
                    throw ClipboardHistoryStoreError.fileReferenceUnavailable
                }
                current = updated
            } catch {
                statusMessage = "重新关联失败，副本仍保留：\(error.localizedDescription)"
                return
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "移除本地文件副本？"
            alert.informativeText = "会释放 ClipHoook 中该文件副本占用的空间；卡片继续引用原文件。原文件日后移动或删除时，卡片将无法粘贴。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "移除副本")
            alert.addButton(withTitle: "取消")
            guard panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        }
        do {
            try store.removeSavedFileCopy(for: current)
            panel.hideDetail()
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = nil
            showToast("已移除文件副本，保留原文件引用")
            if let updated = store.entries.first(where: { $0.id == entry.id }) {
                store.requestThumbnail(for: updated) { [weak self] in
                    self?.entries = self?.store.rootEntries ?? []
                }
            }
        } catch {
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = "移除副本失败：\(error.localizedDescription)"
            let failure = NSAlert()
            failure.messageText = "未能移除文件副本"
            failure.informativeText = error.localizedDescription
            failure.addButton(withTitle: "好")
            _ = panel.performModalInteraction { failure.runModal() }
        }
    }

    private func retryHotKeyIfNeeded() {
        guard !isRecordingShortcut, !hotKeyRegistered,
              Date().timeIntervalSince(lastHotKeyAttempt) >= 5 else { return }
        lastHotKeyAttempt = .now
        hotKeyRegistered = hotKey.register(openPanelShortcut)
        if hotKeyRegistered {
            if statusMessage == hotKeyConflictMessageShown { statusMessage = nil }
            hotKeyConflictMessageShown = nil
        } else {
            let message = "\(openPanelShortcut.displayName) 注册失败，可能被其他应用占用；仍可从菜单栏打开。"
            hotKeyConflictMessageShown = message
            statusMessage = message
        }
    }

    private func retryQuickSearchHotKeyIfNeeded() {
        guard !isRecordingShortcut, !quickSearchHotKeyRegistered,
              Date().timeIntervalSince(lastQuickSearchHotKeyAttempt) >= 5 else { return }
        lastQuickSearchHotKeyAttempt = .now
        quickSearchHotKeyRegistered = quickSearchHotKey.register(shortcut(for: .quickSearch))
        if !quickSearchHotKeyRegistered {
            statusMessage = "\(shortcut(for: .quickSearch).displayName) 快速搜索快捷键无法注册，请在设置中更换；也可从菜单栏打开。"
        }
    }

    private func retryScreenshotHotKeysIfNeeded() {
        guard !isRecordingShortcut,
              registeredScreenshotHotKeys.count < screenshotHotKeys.count,
              Date().timeIntervalSince(lastScreenshotHotKeyAttempt) >= 5 else { return }
        lastScreenshotHotKeyAttempt = .now
        var failed: [String] = []
        for (action, hotKey) in screenshotHotKeys where !registeredScreenshotHotKeys.contains(action) {
            let key = shortcut(for: action)
            if hotKey.register(key) { registeredScreenshotHotKeys.insert(action) }
            else { failed.append("\(action.title)（\(key.displayName)）") }
        }
        if !failed.isEmpty {
            statusMessage = failed.joined(separator: "、") + "注册失败，请在设置中更换快捷键；也可从菜单栏使用。"
        }
    }

    private func refreshPastePermission() {
        guard needsPastePermission else { return }
        if case .ready = PasteService.availability(requestPermission: false) {
            needsPastePermission = false
            if statusMessage == Self.pastePermissionMessage {
                statusMessage = nil
                pasteFallbackPanel.dismiss()
            }
        }
    }

    private func cleanHistoryIfNeeded() {
        guard Date().timeIntervalSince(lastHistoryCleanup) >= 300 else { return }
        lastHistoryCleanup = .now
        applyHistoryStorageSettings()
    }

    private func pollPasteboard(
        forceCapture: Bool = false, allowUnavailableImagePlaceholder: Bool = false
    ) {
        let board = NSPasteboard.general
        let changeCount = board.changeCount
        let change = clipboardChanges.observe(changeCount: changeCount)
        let source = NSWorkspace.shared.frontmostApplication
        let previousForegroundBundleID = lastPolledForegroundBundleID
        let foregroundChanged = foregroundActivationCount != activationCountAtLastPoll
            || source?.bundleIdentifier != previousForegroundBundleID
        lastPolledForegroundBundleID = source?.bundleIdentifier
        activationCountAtLastPoll = foregroundActivationCount
        if change.shouldNotify {
            playCopyFeedback()
        }
        guard change.shouldHandle || forceCapture else { return }
        if isPaused {
            clipboardChanges.markHandled(changeCount: changeCount)
            return
        }

        if #available(macOS 15.4, *) {
            switch board.accessBehavior {
            case .alwaysDeny:
                statusMessage = "剪贴板访问已被系统拒绝；请在系统设置中允许。"
                return
            case .ask:
                statusMessage = "持续记录需要将本应用的剪贴板访问设为“始终允许”。"
                return
            case .default, .alwaysAllow:
                break
            @unknown default:
                break
            }
        }

        // A pairing URL can re-enter the pasteboard through Universal
        // Clipboard after being copied in Settings. Never persist that secret.
        if let pastedString = board.string(forType: .string),
           pastedString == phoneScreenshotEndpoint || pastedString == phoneScreenshotSetupAddress {
            clipboardChanges.markHandled(changeCount: changeCount)
            return
        }

        guard RecordingExclusionPolicy.configurationIsValid(in: .standard) else {
            clipboardChanges.markHandled(changeCount: changeCount)
            statusMessage = "应用排除设置无法读取，已暂停保存；请在设置中重新添加排除应用。"
            return
        }
        let weChatMultiSelection = ClipboardBatchCapture.isWeChatMultiSelection(board)
        guard RecordingExclusionPolicy.shouldRecord(
            sourceBundleID: weChatMultiSelection
                ? "com.tencent.xinWeChat" : source?.bundleIdentifier,
            foregroundChangedSinceLastPoll: foregroundChanged
                && !weChatMultiSelection,
            excluded: excludedApplications
        ) else {
            clipboardChanges.markHandled(changeCount: changeCount)
            return
        }
        // Opening our panel immediately after copying can make ClipHoook the
        // frontmost app before this poll. In that narrow case the preceding
        // WeChat app is still the best source for resolving its temporary
        // image URLs; other foreground changes remain unattributed.
        let copiedFromWeChatBeforeOpeningPanel = foregroundChanged
            && source?.bundleIdentifier == Bundle.main.bundleIdentifier
            && ClipboardImageCapture.isWeChatSource(
                name: nil, bundleID: previousForegroundBundleID
            )
        let sourceApp = weChatMultiSelection ? "微信" : (
            foregroundChanged
                ? (copiedFromWeChatBeforeOpeningPanel ? "微信" : nil)
                : source?.localizedName
        )
        let sourceBundleID = weChatMultiSelection ? "com.tencent.xinWeChat" : (
            foregroundChanged
                ? (copiedFromWeChatBeforeOpeningPanel ? previousForegroundBundleID : nil)
                : source?.bundleIdentifier
        )

        do {
            let captured = try ClipboardBatchCapture.capture(
                from: board, sourceAppName: sourceApp, sourceAppBundleID: sourceBundleID,
                maximumImageBytes: store.maximumImageBytes,
                maximumTextBytes: store.maximumTextBytes,
                maximumRichTextBytes: store.maximumRichTextBytes,
                allowUnavailableImagePlaceholder: allowUnavailableImagePlaceholder
            )
            let copiedFromWeChat = ClipboardImageCapture.isWeChatSource(
                name: sourceApp, bundleID: sourceBundleID
            )
            let added = try store.addCapturedBatch(
                captured, sourceAppName: sourceApp, sourceAppBundleID: sourceBundleID,
                automaticallyGroup: ClipboardGroupingPreference.isEnabled(),
                preserveOccurrences: copiedFromWeChat
            )
            clipboardChanges.markHandled(changeCount: changeCount)
            let missingImageCount = captured.reduce(into: 0) { count, item in
                if case .unavailableImage = item { count += 1 }
            }
            statusMessage = missingImageCount == 0 ? nil
                : "已记录这次复制；\(missingImageCount) 张微信图片未保存，已显示占位符。"
            if added {
                entries = store.rootEntries
                prepareOCRIfNeeded()
                refreshStorageSizes(force: false)
                let filePaths = Set(captured.compactMap { item -> String? in
                    if case .fileReference(let url, _) = item { return url.standardizedFileURL.path }
                    return nil
                })
                for entry in store.entries where entry.kind == .fileReference
                    && entry.filePath.map(filePaths.contains) == true {
                    store.requestThumbnail(for: entry) { [weak self] in
                        self?.entries = self?.store.rootEntries ?? []
                        self?.refreshStorageSizes(force: false)
                    }
                }
            }
        } catch {
            let retrying: Bool
            if let captureError = error as? ClipboardBatchCaptureError {
                switch captureError {
                case .incompleteBatch, .unavailableChatImage:
                    retrying = clipboardChanges.deferHandling(changeCount: changeCount)
                    if !retrying, case .unavailableChatImage = captureError {
                        pollPasteboard(forceCapture: true,
                                       allowUnavailableImagePlaceholder: true)
                        return
                    }
                case .oversizedText:
                    clipboardChanges.markHandled(changeCount: changeCount)
                    retrying = false
                }
            } else {
                clipboardChanges.markHandled(changeCount: changeCount)
                retrying = false
            }
            entries = store.rootEntries
            refreshStorageSizes(force: false)
            if !retrying {
                statusMessage = error is ClipboardBatchCaptureError
                    ? error.localizedDescription
                    : "保存剪贴板内容失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshStorageSizes(force: Bool = true) {
        if !force && Date().timeIntervalSince(lastStorageRefresh) < 5 {
            storageRefreshPending = true
            return
        }
        lastStorageRefresh = .now
        storageRefreshPending = false
        historyStorageBytes = store.activeStorageBytes
        migrationBackupBytes = store.migrationBackupBytes
        recoveryBytes = store.recoveryBytes
        pinnedStorageBytes = pinnedStore?.storageBytes ?? 0
        pinnedImageCount = pinnedStore?.count ?? 0
    }

    private func remindAboutUncappedHistoryIfNeeded() {
        let defaults = UserDefaults.standard
        let maximumBytes = HistoryStoragePolicy(defaults: defaults).maximumBytes
        let lastLevel = defaults.integer(forKey: HistoryStorageReminder.lastNotifiedLevelKey)
        guard let level = HistoryStorageReminder.nextLevel(
            actualBytes: historyStorageBytes,
            maximumBytes: maximumBytes,
            lastNotifiedLevel: lastLevel
        ) else { return }
        defaults.set(level, forKey: HistoryStorageReminder.lastNotifiedLevelKey)
        let size = ByteCountFormatter.string(fromByteCount: historyStorageBytes, countStyle: .file)
        showToast("历史已占用 \(size)；可在设置中选择存储上限", duration: .seconds(5))
    }

    private func defaultCopyMode(for entry: ClipboardEntry) -> ClipboardPasteboardWriter.Mode {
        let rawValue = UserDefaults.standard.string(forKey: ClipboardCopyFormat.preferenceKey) ?? ""
        let preference = ClipboardCopyFormat(rawValue: rawValue) ?? .original
        return preference.mode(for: entry)
    }

    private func writeToPasteboard(
        _ entry: ClipboardEntry,
        mode: ClipboardPasteboardWriter.Mode
    ) -> Bool {
        writeToPasteboard([entry], mode: mode)
    }

    private func writeToPasteboard(
        _ entries: [ClipboardEntry],
        mode: ClipboardPasteboardWriter.Mode
    ) -> Bool {
        let board = NSPasteboard.general
        let reuseOriginal = mode == .original
            && ClipboardPasteboardWriter.canReuseOriginalWeChatFile(entries, on: board)
        let succeeded = reuseOriginal
            || ClipboardPasteboardWriter.write(entries, from: store, to: board, mode: mode)
        if succeeded {
            if !reuseOriginal {
                clipboardChanges.markOwnWrite(changeCount: board.changeCount)
            }
            playCopyFeedback()
        }
        return succeeded
    }
}
