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

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController(store: ClipboardHistoryStore())
    private static let pastePermissionMessage = "已复制，请手动按 ⌘V；允许键盘事件权限后可自动粘贴。"
    private static let copiedMessage = "已复制到剪贴板"

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var toastMessage: String?
    @Published private(set) var hotKeyRegistered = false
    @Published private(set) var shortcuts: [AppShortcutAction: AppShortcut] = [:]
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
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: "recordingPaused") }
    }

    private let store: ClipboardHistoryStore
    private let hotKey = GlobalHotKey()
    private lazy var panel = PanelController(model: self)
    private var timer: Timer?
    private var toastDismissTask: Task<Void, Never>?
    private var lastHotKeyAttempt = Date.distantPast
    private var isRecordingShortcut = false
    private var hotKeyConflictMessageShown: String?
    private var lastHistoryCleanup = Date.distantPast
    private var lastStorageRefresh = Date.distantPast
    private var storageRefreshPending = false
    private var clipboardChanges: ClipboardChangeTracker
    private var started = false
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
        var loaded: [AppShortcutAction: AppShortcut] = [:]
        for action in AppShortcutAction.allCases {
            let candidate = AppShortcutPreference.load(
                action.preferenceKey, fallback: action.defaultShortcut,
                requiresModifier: action == .openPanel
            )
            loaded[action] = candidate
        }
        // Keep every action distinct when upgrading older preferences. Earlier
        // user choices take priority over defaults introduced in this build.
        var resolved: [AppShortcutAction: AppShortcut] = [:]
        for action in AppShortcutAction.allCases {
            guard let candidate = loaded[action] else { continue }
            if resolved.values.contains(where: { $0.hasSameKeys(as: candidate) }) {
                if action == .copyOnly {
                    // Earlier builds allowed ⌘C as a custom global/delete key.
                    // Keep that choice and retain the former copy binding.
                    resolved[action] = AppShortcut(
                        keyCode: UInt16(kVK_Return), modifiers: [.command], keyLabel: "↩"
                    )
                } else {
                    resolved[action] = action.defaultShortcut
                }
            } else {
                resolved[action] = candidate
            }
        }
        shortcuts = resolved
        clipboardChanges = ClipboardChangeTracker(initialChangeCount: NSPasteboard.general.changeCount)
        isPaused = UserDefaults.standard.bool(forKey: "recordingPaused")
        entries = store.rootEntries
        statusMessage = store.errorMessage
        excludedApplications = RecordingExclusionPolicy.applications(in: .standard)
        refreshStorageSizes()
    }

    func openSettings() {
        refreshStorageSizes()
        // Wait until the screen-level panel has finished leaving the screen.
        // Otherwise its deferred focus promotion can cover the first Settings
        // window, leaving only the Dock icon visible.
        panel.hide(restorePreviousApplication: false) {
            SettingsWindowController.shared.open()
        }
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
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.foregroundActivationCount += 1 }
        }
        retryHotKeyIfNeeded()
        let captureTimer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryHotKeyIfNeeded()
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
    }

    func togglePanel() {
        if panel.isVisible {
            panel.hide()
        } else {
            dismissToast()
            if statusMessage == Self.copiedMessage
                || statusMessage?.hasPrefix("已复制，请手动按 ⌘V") == true {
                statusMessage = nil
            }
            panelPresentationID = UUID()
            panel.show()
        }
    }

    func closePanel() {
        panel.hide()
    }

    func openSourceApplication(for entry: ClipboardEntry) {
        let bundleID = entry.sourceAppBundleID
        let name = entry.sourceAppName
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
        onKeyDown: @escaping (NSEvent) -> Bool,
        onClose: @escaping () -> Void
    ) -> Bool {
        panel.showDetail(entry, cardFrame: cardFrame,
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
    }

    func endShortcutRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        lastHotKeyAttempt = .distantPast
        retryHotKeyIfNeeded()
    }

    /// Keeps registration, collision checks, persistence and live panel input
    /// on the same mapping. A failed global registration leaves the old key.
    func setShortcut(_ shortcut: AppShortcut, for action: AppShortcutAction) -> String? {
        guard action == .openPanel ? shortcut.isValid : shortcut.isValidForPanel else {
            return action == .openPanel
                ? "唤起面板需要 Command、Control 或 Option 与其他按键组合。"
                : "此按键不能用于面板操作；单键可选方向键、空格、Return 等功能键。"
        }
        if let conflict = AppShortcutAction.allCases.first(where: {
            $0 != action && self.shortcut(for: $0).hasSameKeys(as: shortcut)
        }) {
            return "\(shortcut.displayName) 已用于“\(conflict.title)”。"
        }
        if action == .openPanel {
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
        }
        shortcuts[action] = shortcut
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
        guard writeToPasteboard(entry, mode: defaultCopyMode(for: entry)) else {
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

    func copySelection(_ selection: [ClipboardEntry]) {
        guard selection.count > 1 else {
            if let entry = selection.first { copy(entry) }
            return
        }
        let members = expandedSelection(selection)
        if members.count == 1 {
            copy(members[0])
            return
        }
        guard writeToPasteboard(members, mode: .original) else {
            statusMessage = members.contains(where: { $0.kind == .unavailableImage })
                ? "所选内容包含未保存的微信图片，不能完整复制；可单独复制文字。"
                : "复制失败；选中的项目可能已不可用。"
            return
        }
        do {
            guard try store.recordBatchCopy(
                of: members.map(\.id),
                automaticallyGroup: ClipboardGroupingPreference.isEnabled()
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

    func paste(_ entry: ClipboardEntry) {
        paste(entry, mode: defaultCopyMode(for: entry))
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

    private func paste(_ selected: [ClipboardEntry], mode: ClipboardPasteboardWriter.Mode) {
        guard writeToPasteboard(selected, mode: mode) else {
            statusMessage = selected.contains(where: \.containsUnavailableImage)
                ? "这次复制包含未保存的微信图片，不能完整粘贴；可单独粘贴文字。"
                : selected.contains(where: { $0.kind == .fileReference })
                ? "原文件和保存的副本都不可用；请重新选择文件。"
                : "粘贴失败，原始内容可能已不可用。"
            return
        }
        switch PasteService.availability(requestPermission: true) {
        case .needsPermission:
            needsPastePermission = true
            showManualPasteMessage(Self.pastePermissionMessage, target: panel.previousApplication)
        case .ready:
            needsPastePermission = false
            guard let target = panel.previousApplication, !target.isTerminated else {
                showManualPasteMessage("已复制，请手动按 ⌘V；未找到原应用。", target: nil)
                return
            }
            guard let originalTarget = panel.previousTarget,
                  originalTarget.processIdentifier == target.processIdentifier else {
                showManualPasteMessage("已复制，请手动按 ⌘V；无法核对原输入位置。", target: target)
                return
            }
            panel.hide(restorePreviousApplication: false) { [weak self] in
                guard let self else { return }
                guard target.activate(options: []) else {
                    self.statusMessage = "已复制，请手动按 ⌘V；无法切回原应用。"
                    return
                }
                Task { @MainActor in
                    let deadline = Date().addingTimeInterval(1.5)
                    while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                        guard Date() < deadline else {
                            self.statusMessage = "已复制，请手动按 ⌘V；原应用未回到前台。"
                            return
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    // The original input element or window may return shortly after
                    // the process becomes frontmost. Wait for the captured target.
                    while !originalTarget.stillMatches() {
                        guard Date() < deadline,
                              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                            self.statusMessage = "已复制，请手动按 ⌘V；原输入位置已变化或无法核对。"
                            return
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                        self.statusMessage = "已复制，请手动按 ⌘V；原应用焦点已变化。"
                        return
                    }
                    guard originalTarget.stillMatches() else {
                        self.statusMessage = "已复制，请手动按 ⌘V；原输入位置已变化。"
                        return
                    }
                    let sent = PasteService.sendPasteShortcut(to: target.processIdentifier)
                    self.statusMessage = sent
                        ? "已向原应用发送粘贴快捷键；目标应用是否接收无法确认。"
                        : "已复制，请手动按 ⌘V；自动粘贴未发出。"
                }
            }
        }
    }

    private func showManualPasteMessage(_ message: String, target: NSRunningApplication?) {
        // Keep the fallback available in the menu bar without replacing the panel's
        // persistent keyboard hints with a transient orange banner.
        panel.hide(restorePreviousApplication: false) { [weak self] in
            self?.statusMessage = message
            if let target, !target.isTerminated { _ = target.activate(options: []) }
        }
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
        alert.informativeText = "这会删除本机保存的历史记录、图片、富文本和文件副本，无法撤销；不会删除原文件或清空系统剪贴板。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn {
            do {
                try store.clear()
                entries = []
                refreshStorageSizes()
                statusMessage = "历史记录已清空"
            } catch {
                entries = store.rootEntries
                refreshStorageSizes()
                statusMessage = "清空失败：\(error.localizedDescription)"
            }
        }
    }

    func confirmDelete(_ entry: ClipboardEntry) {
        let alert = NSAlert()
        alert.messageText = "删除这条历史记录？"
        alert.informativeText = "只删除本机保存的这条记录及其副本，不会删除原文件或清空当前系统剪贴板。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard panel.performModalInteraction({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        do {
            try store.delete(entry)
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = nil
            showToast("已删除")
        } catch {
            entries = store.rootEntries
            refreshStorageSizes()
            statusMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
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

    func addExcludedApplication() {
        let picker = NSOpenPanel()
        picker.message = "选择不记录剪贴板内容的应用"
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard panel.performModalInteraction({ picker.runModal() }) == .OK, let url = picker.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        excludedApplications.removeAll { $0.bundleIdentifier == bundleID }
        excludedApplications.append(ExcludedApplication(bundleIdentifier: bundleID, name: name))
        excludedApplications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        RecordingExclusionPolicy.save(excludedApplications, in: .standard)
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

    func filePreviewAccess(for entry: ClipboardEntry) -> FilePreviewAccess? {
        store.filePreviewAccess(for: entry)
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

    private func refreshPastePermission() {
        guard needsPastePermission else { return }
        if case .ready = PasteService.availability(requestPermission: false) {
            needsPastePermission = false
            if statusMessage == Self.pastePermissionMessage {
                statusMessage = nil
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
            CopySoundPlayer.shared.playIfEnabled()
        }
        guard change.shouldHandle || forceCapture else { return }
        if isPaused {
            clipboardChanges.markHandled(changeCount: changeCount)
            return
        }

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
                refreshStorageSizes(force: false)
                let filePaths = Set(captured.compactMap { item -> String? in
                    if case .fileReference(let url) = item { return url.standardizedFileURL.path }
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
        let succeeded = ClipboardPasteboardWriter.write(entries, from: store, to: board, mode: mode)
        if succeeded {
            clipboardChanges.markOwnWrite(changeCount: board.changeCount)
            CopySoundPlayer.shared.playIfEnabled()
        }
        return succeeded
    }
}
