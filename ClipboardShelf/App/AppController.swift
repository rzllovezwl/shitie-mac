import AppKit
import Combine

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController(store: ClipboardHistoryStore())
    private static let hotKeyConflictMessage = "⌘⇧V 注册失败，可能被其他应用占用；仍可从菜单栏打开。"
    private static let pastePermissionMessage = "已复制；允许本应用发送键盘事件后，双击即可自动粘贴。现在可手动按 ⌘V。"

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var hotKeyRegistered = false
    @Published private(set) var needsPastePermission = false
    @Published private(set) var panelPresentationID = UUID()
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: "recordingPaused") }
    }

    private let store: ClipboardHistoryStore
    private let hotKey = GlobalHotKey()
    private lazy var panel = PanelController(model: self)
    private var timer: Timer?
    private var lastHotKeyAttempt = Date.distantPast
    private var clipboardChanges: ClipboardChangeTracker
    private var started = false

    init(store: ClipboardHistoryStore) {
        self.store = store
        clipboardChanges = ClipboardChangeTracker(initialChangeCount: NSPasteboard.general.changeCount)
        isPaused = UserDefaults.standard.bool(forKey: "recordingPaused")
        entries = store.entries
        statusMessage = store.errorMessage
    }

    func openSettings() {
        SettingsWindowController.shared.open()
    }

    func start() {
        guard !started else { return }
        started = true
        if case .needsPermission = PasteService.availability(requestPermission: false) {
            needsPastePermission = true
        }
        _ = CopySoundPlayer.shared
        _ = panel
        retryHotKeyIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryHotKeyIfNeeded()
                self?.refreshPastePermission()
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

    func updatePanelHeight(_ preference: String) {
        panel.updateHeightIfVisible(preference)
    }

    func copy(_ entry: ClipboardEntry) {
        guard writeToPasteboard(entry) else {
            statusMessage = "复制失败，原始内容可能已不可用。"
            return
        }
        statusMessage = "已复制到剪贴板"
        panel.hide()
    }

    func paste(_ entry: ClipboardEntry) {
        guard writeToPasteboard(entry) else {
            statusMessage = "粘贴失败，原始内容可能已不可用。"
            return
        }
        switch PasteService.availability(requestPermission: true) {
        case .needsPermission:
            needsPastePermission = true
            statusMessage = Self.pastePermissionMessage
            panel.hide()
        case .ready:
            needsPastePermission = false
            guard let target = panel.previousApplication, !target.isTerminated else {
                statusMessage = "已复制；未找到原应用，请手动按 ⌘V。"
                panel.hide()
                return
            }
            panel.hide { [weak self] in
                guard let self else { return }
                guard target.activate(options: []) else {
                    self.statusMessage = "已复制；无法切回原应用，请手动按 ⌘V。"
                    return
                }
                Task { @MainActor in
                    let deadline = Date().addingTimeInterval(1.5)
                    while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                        guard Date() < deadline else {
                            self.statusMessage = "已复制；原应用未回到前台，请手动按 ⌘V。"
                            return
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                        self.statusMessage = "已复制；原应用焦点已变化，请手动按 ⌘V。"
                        return
                    }
                    let sent = PasteService.sendPasteShortcut(to: target.processIdentifier)
                    self.statusMessage = sent ? nil : "已复制；自动粘贴未发出，请手动按 ⌘V。"
                }
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
        alert.informativeText = "这会删除本机保存的所有历史记录和图片，无法撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try store.clear()
                entries = []
                statusMessage = "历史记录已清空"
            } catch {
                statusMessage = "清空失败：\(error.localizedDescription)"
            }
        }
    }

    func imageURL(for entry: ClipboardEntry) -> URL? {
        store.imageURL(for: entry)
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

    private func pollPasteboard() {
        let board = NSPasteboard.general
        let changeCount = board.changeCount
        let change = clipboardChanges.observe(changeCount: changeCount)
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
        guard let item = board.pasteboardItems?.first else { return }
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        do {
            let added: Bool
            if let image = item.data(forType: .png) {
                added = try store.addImage(image, type: NSPasteboard.PasteboardType.png.rawValue, sourceAppName: sourceApp)
            } else if let image = item.data(forType: .tiff) {
                added = try store.addImage(image, type: NSPasteboard.PasteboardType.tiff.rawValue, sourceAppName: sourceApp)
            } else if let text = item.string(forType: .string) {
                added = try store.addText(text, sourceAppName: sourceApp)
            } else {
                return
            }
            if added {
                entries = store.entries
                statusMessage = nil
            }
        } catch {
            statusMessage = "保存剪贴板内容失败：\(error.localizedDescription)"
        }
    }

    private func writeToPasteboard(_ entry: ClipboardEntry) -> Bool {
        let board = NSPasteboard.general
        let succeeded: Bool
        switch entry.kind {
        case .text, .link:
            board.clearContents()
            succeeded = board.setString(entry.text ?? "", forType: .string)
        case .image:
            guard let url = store.imageURL(for: entry), let data = try? Data(contentsOf: url) else { return false }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(entry.imagePasteboardType ?? "public.png"))
            board.clearContents()
            succeeded = board.writeObjects([item])
        }
        clipboardChanges.markOwnWrite(changeCount: board.changeCount)
        if succeeded {
            CopySoundPlayer.shared.playIfEnabled()
        }
        return succeeded
    }
}
