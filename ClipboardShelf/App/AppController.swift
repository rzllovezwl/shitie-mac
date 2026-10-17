import AppKit
import Combine
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
    private static let hotKeyConflictMessage = "⌘⇧V 注册失败，可能被其他应用占用；仍可从菜单栏打开。"
    private static let pastePermissionMessage = "已复制，请手动按 ⌘V；允许键盘事件权限后可自动粘贴。"

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var hotKeyRegistered = false
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
    private let pinnedImages = PinnedImageWindowController()
    private var timer: Timer?
    private var lastHotKeyAttempt = Date.distantPast
    private var lastHistoryCleanup = Date.distantPast
    private var lastStorageRefresh = Date.distantPast
    private var storageRefreshPending = false
    private var clipboardChanges: ClipboardChangeTracker
    private var started = false
    private var foregroundActivationCount = 0
    private var activationCountAtLastPoll = 0
    private var lastPolledForegroundBundleID: String?
    private var activationObserver: NSObjectProtocol?

    init(store: ClipboardHistoryStore) {
        self.store = store
        clipboardChanges = ClipboardChangeTracker(initialChangeCount: NSPasteboard.general.changeCount)
        isPaused = UserDefaults.standard.bool(forKey: "recordingPaused")
        entries = store.entries
        statusMessage = store.errorMessage
        excludedApplications = RecordingExclusionPolicy.applications(in: .standard)
        refreshStorageSizes()
    }

    func openSettings() {
        refreshStorageSizes()
        SettingsWindowController.shared.open()
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
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
    }

    func togglePanel() {
        if panel.isVisible {
            panel.hide()
        } else {
            panelPresentationID = UUID()
            panel.show()
        }
    }

    func closePanel() {
        panel.hide()
    }

    func updatePanelLayout() {
        panel.updateLayoutIfVisible()
    }

    func updateAppearance(_ rawValue: String?) {
        let mode = AppAppearanceMode(rawValue: rawValue ?? "") ?? .system
        NSApp.appearance = mode.appearance
    }

    func applyHistoryStorageSettings() {
        do {
            if try store.applyStoragePolicy() {
                entries = store.entries
            }
            refreshStorageSizes()
        } catch {
            entries = store.entries
            refreshStorageSizes()
            statusMessage = "清理历史记录失败：\(error.localizedDescription)"
        }
    }

    func copy(_ entry: ClipboardEntry) {
        guard writeToPasteboard(entry) else {
            statusMessage = entry.kind == .fileReference
                ? "原文件和保存的副本都不可用；请重新选择文件。"
                : "复制失败，原始内容可能已不可用。"
            return
        }
        statusMessage = "已复制到剪贴板"
        panel.hide()
    }

    func pinImage(_ entry: ClipboardEntry) {
        guard entry.kind == .image,
              let url = store.imageURL(for: entry),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else {
            statusMessage = "图片文件不可用，无法固定到桌面。"
            return
        }
        pinnedImages.show(entryID: entry.id, image: image)
        panel.hide()
    }

    func paste(_ entry: ClipboardEntry) {
        paste(entry, mode: .original)
    }

    func pastePlainText(_ entry: ClipboardEntry) {
        guard entry.kind == .text || entry.kind == .link else {
            statusMessage = "这条记录没有纯文本；可按 Return 保留原格式粘贴。"
            return
        }
        paste(entry, mode: .plainText)
    }

    private func paste(_ entry: ClipboardEntry, mode: ClipboardPasteboardWriter.Mode) {
        guard writeToPasteboard(entry, mode: mode) else {
            statusMessage = entry.kind == .fileReference
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
            guard let originalFocus = panel.previousFocus,
                  originalFocus.processIdentifier == target.processIdentifier else {
                showManualPasteMessage("已复制，请手动按 ⌘V；无法核对原输入位置。", target: target)
                return
            }
            panel.hide { [weak self] in
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
                    // Activation may restore the previous editor a moment after
                    // the process becomes frontmost. Do not paste into another field.
                    while !originalFocus.stillMatches() {
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
                    guard originalFocus.stillMatches() else {
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
        statusMessage = message
        let presentationID = panelPresentationID
        // Give the user a moment to read the fallback in the panel footer.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard panelPresentationID == presentationID, panel.isVisible else { return }
            panel.hide {
                if let target, !target.isTerminated { _ = target.activate(options: []) }
            }
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
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try store.clear()
                entries = []
                refreshStorageSizes()
                statusMessage = "历史记录已清空"
            } catch {
                entries = store.entries
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.delete(entry)
            entries = store.entries
            refreshStorageSizes()
            statusMessage = "已删除历史记录"
        } catch {
            entries = store.entries
            refreshStorageSizes()
            statusMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func addExcludedApplication() {
        let picker = NSOpenPanel()
        picker.message = "选择不记录剪贴板内容的应用"
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url,
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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

    func thumbnailURL(for entry: ClipboardEntry) -> URL? {
        store.thumbnailURL(for: entry)
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

    func saveFileCopy(_ entry: ClipboardEntry) {
        guard entry.kind == .fileReference else { return }
        var replacement: URL?
        if !store.originalFileIsAvailable(entry) {
            let picker = NSOpenPanel()
            picker.message = "原文件不可用。请选择要保存副本的原文件。"
            picker.canChooseDirectories = false
            picker.allowsMultipleSelection = false
            guard picker.runModal() == .OK, let selected = picker.url else { return }
            replacement = selected
        }
        Task { @MainActor [self] in
            do {
                try await store.saveFileCopy(for: entry, using: replacement)
                entries = store.entries
                refreshStorageSizes()
                statusMessage = "文件副本已保存；以后原文件移动也可使用副本。"
                if let updated = entries.first(where: { $0.id == entry.id }) {
                    store.requestThumbnail(for: updated) { [weak self] in
                        self?.entries = self?.store.entries ?? []
                    }
                }
            } catch {
                statusMessage = "保存文件副本失败：\(error.localizedDescription)"
            }
        }
    }

    private func retryHotKeyIfNeeded() {
        guard !hotKeyRegistered, Date().timeIntervalSince(lastHotKeyAttempt) >= 5 else { return }
        lastHotKeyAttempt = .now
        hotKeyRegistered = hotKey.register()
        if hotKeyRegistered {
            if statusMessage == Self.hotKeyConflictMessage { statusMessage = nil }
        } else {
            statusMessage = Self.hotKeyConflictMessage
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

    private func pollPasteboard() {
        let board = NSPasteboard.general
        let changeCount = board.changeCount
        let change = clipboardChanges.observe(changeCount: changeCount)
        let source = NSWorkspace.shared.frontmostApplication
        let foregroundChanged = foregroundActivationCount != activationCountAtLastPoll
            || source?.bundleIdentifier != lastPolledForegroundBundleID
        lastPolledForegroundBundleID = source?.bundleIdentifier
        activationCountAtLastPoll = foregroundActivationCount
        if change.shouldNotify {
            CopySoundPlayer.shared.playIfEnabled()
        }
        guard change.shouldHandle else { return }
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

        clipboardChanges.markHandled(changeCount: changeCount)
        guard RecordingExclusionPolicy.configurationIsValid(in: .standard) else {
            statusMessage = "应用排除设置无法读取，已暂停保存；请在设置中重新添加排除应用。"
            return
        }
        guard RecordingExclusionPolicy.shouldRecord(
            sourceBundleID: source?.bundleIdentifier,
            foregroundChangedSinceLastPoll: foregroundChanged,
            excluded: excludedApplications
        ) else { return }
        guard let item = board.pasteboardItems?.first else { return }
        let sourceApp = foregroundChanged ? nil : source?.localizedName
        let sourceBundleID = foregroundChanged ? nil : source?.bundleIdentifier

        do {
            let added: Bool
            let fileURLs = (board.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) ?? []).compactMap { $0 as? URL }.filter(\.isFileURL)
            if !fileURLs.isEmpty {
                var anyAdded = false
                for url in fileURLs {
                    if try store.addFileReference(url, sourceAppName: sourceApp, sourceAppBundleID: sourceBundleID) {
                        anyAdded = true
                    }
                }
                added = anyAdded
                for entry in store.entries where entry.kind == .fileReference
                    && fileURLs.contains(where: { $0.standardizedFileURL.path == entry.filePath }) {
                    store.requestThumbnail(for: entry) { [weak self] in
                        self?.entries = self?.store.entries ?? []
                        self?.refreshStorageSizes(force: false)
                    }
                }
            } else if let image = item.data(forType: .png) {
                added = try store.addImage(image, type: NSPasteboard.PasteboardType.png.rawValue, sourceAppName: sourceApp, sourceAppBundleID: sourceBundleID)
            } else if let image = item.data(forType: .tiff) {
                added = try store.addImage(image, type: NSPasteboard.PasteboardType.tiff.rawValue, sourceAppName: sourceApp, sourceAppBundleID: sourceBundleID)
            } else {
                let rtf = item.data(forType: .rtf)
                let html = item.data(forType: .html)
                let rtfd = item.data(forType: .rtfd)
                let text = item.string(forType: .string)
                    ?? plainText(from: rtf, type: .rtf)
                    ?? plainText(from: html, type: .html)
                    ?? plainText(from: rtfd, type: .rtfd)
                guard let text else { return }
                if rtf != nil || html != nil || rtfd != nil {
                    added = try store.addRichText(
                        text, rtf: rtf, html: html, rtfd: rtfd,
                        sourceAppName: sourceApp, sourceAppBundleID: sourceBundleID
                    )
                } else {
                    added = try store.addText(text, sourceAppName: sourceApp, sourceAppBundleID: sourceBundleID)
                }
            }
            if added {
                entries = store.entries
                refreshStorageSizes(force: false)
                statusMessage = nil
            }
        } catch {
            entries = store.entries
            refreshStorageSizes(force: false)
            statusMessage = "保存剪贴板内容失败：\(error.localizedDescription)"
        }
    }

    private func plainText(from data: Data?, type: NSAttributedString.DocumentType) -> String? {
        guard let data, data.count <= store.maximumRichTextBytes else { return nil }
        return try? NSAttributedString(
            data: data, options: [.documentType: type], documentAttributes: nil
        ).string
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

    private func writeToPasteboard(
        _ entry: ClipboardEntry,
        mode: ClipboardPasteboardWriter.Mode = .original
    ) -> Bool {
        let board = NSPasteboard.general
        let succeeded = ClipboardPasteboardWriter.write(entry, from: store, to: board, mode: mode)
        if succeeded {
            clipboardChanges.markOwnWrite(changeCount: board.changeCount)
            CopySoundPlayer.shared.playIfEnabled()
        }
        return succeeded
    }
}
