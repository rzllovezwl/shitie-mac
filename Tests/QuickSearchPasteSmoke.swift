import AppKit
import Foundation

// The production routing methods are injected below. These endpoints never
// post keys, activate an app, read a user's clipboard or open real panels.
private struct PasteTargetSnapshot { let processIdentifier: pid_t; let identity: String }
private final class SearchTestApplication {
    static let current = SearchTestApplication()
    let processIdentifier: pid_t = 42
    var isTerminated = false
}
private enum ClipboardPasteboardWriter { enum Mode { case original, plainText } }
@MainActor private enum PasteService {
    enum Availability { case ready, needsPermission }
    static var state: Availability = .ready
    static func availability(requestPermission: Bool) -> Availability { state }
}
@MainActor private final class SearchPastePanel {
    var previousApplication: NSRunningApplication? = .current
    var previousTarget: PasteTargetSnapshot? = PasteTargetSnapshot(
        processIdentifier: NSRunningApplication.current.processIdentifier, identity: "shelf")
    var hides = 0
    func hideForPaste(reclaimingPinKey: Bool, completion: (Bool) -> Void) { hides += 1; completion(true) }
}
@MainActor private final class SearchPasteHandoff {
    var activeID: UUID?
    func begin() -> UUID { let id = UUID(); activeID = id; return id }
}
@MainActor private final class SearchPasteFallback { func dismiss() {} }
private struct SearchPastePins { let hasKeyWindow = false }

@MainActor
private final class AppController {
    enum FileRecoveryAction { case copy, paste }
    static let pastePermissionMessage = "permission"
    let panel = SearchPastePanel()
    let pasteFocusHandoff = SearchPasteHandoff()
    let pasteFallbackPanel = SearchPasteFallback()
    let pinnedWindows: SearchPastePins? = nil
    var needsPastePermission = false
    var statusMessage: String?
    var writes = 0
    var recoveryAttempts = 0
    var canWrite = true
    var destinations: [String] = []
    var modes: [ClipboardPasteboardWriter.Mode] = []
    var manualHasContext = false
    func run(_ entry: ClipboardEntry, context: QuickSearchPasteContext? = nil) {
        paste([entry], mode: .original, context: context)
    }
    func writeToPasteboard(_ selected: [ClipboardEntry], mode: ClipboardPasteboardWriter.Mode) -> Bool {
        writes += 1; modes.append(mode); return canWrite
    }
    func expandedSelection(_ entries: [ClipboardEntry]) -> [ClipboardEntry] { entries }
    func cancelPasteHandoff() { pasteFocusHandoff.activeID = nil }
    func endPasteHandoff(_ id: UUID) { if pasteFocusHandoff.activeID == id { pasteFocusHandoff.activeID = nil } }
    func recoverUnavailableFilesForCopy(_ entries: [ClipboardEntry], action: FileRecoveryAction,
                                       onRecovered: (([ClipboardEntry]) -> Void)? = nil) -> Bool {
        recoveryAttempts += 1
        canWrite = true
        onRecovered?(entries)
        return true
    }
    func completePasteHandoff(_ id: UUID, to app: NSRunningApplication,
                              originalTarget: PasteTargetSnapshot, clipboardChangeCount: Int) async {
        destinations.append(originalTarget.identity)
        endPasteHandoff(id)
    }
    func showManualPasteMessage(_ message: String, target: NSRunningApplication?, context: QuickSearchPasteContext? = nil) {
        statusMessage = message; manualHasContext = context != nil
    }
    // INSERT_PRODUCTION_PASTE_ROUTING
}

// INSERT_PRODUCTION_SEARCH_CONTEXT

@main
private struct QuickSearchPasteSmoke {
    @MainActor static func main() async {
        let entry = ClipboardEntry(id: UUID(), createdAt: .now, kind: .text, text: "test",
            imageFileName: nil, imagePasteboardType: nil, digest: "test", byteCount: 4,
            sourceAppName: nil, sourceAppBundleID: nil)
        let controller = AppController()
        var searchDismisses = 0
        let target = PasteTargetSnapshot(processIdentifier: NSRunningApplication.current.processIdentifier, identity: "search")
        let context = QuickSearchPasteContext(application: .current, target: target) { completion in
            searchDismisses += 1; completion(true)
        }
        controller.run(entry, context: context)
        await settle()
        precondition(searchDismisses == 1 && controller.panel.hides == 0 && controller.destinations == ["search"],
                     "快速搜索只能关闭搜索窗，并使用本次保存的原应用目标，不能沿用主面板旧目标")
        controller.run(entry)
        await settle()
        precondition(controller.panel.hides == 1 && controller.destinations == ["search", "shelf"],
                     "已有面板粘贴路径必须保持原样")
        let cancelled = QuickSearchPasteContext(application: .current, target: target) { $0(false) }
        controller.run(entry, context: cancelled)
        await settle()
        precondition(controller.destinations.count == 2 && controller.pasteFocusHandoff.activeID == nil,
                     "关闭取消或已失效时不能继续粘贴")
        let noTarget = QuickSearchPasteContext(application: nil, target: nil) { $0(true) }
        controller.run(entry, context: noTarget)
        precondition(controller.manualHasContext && controller.statusMessage?.contains("未找到原应用") == true,
                     "搜索没有目标时应提示手动粘贴，不能回退到旧面板目标")
        PasteService.state = .needsPermission
        controller.run(entry, context: context)
        precondition(controller.needsPastePermission && controller.manualHasContext && controller.statusMessage == "permission",
                     "授权提示也必须关闭本次搜索窗")
        PasteService.state = .ready
        var file = entry
        file.kind = .fileReference; file.fileName = "test.dat"
        controller.canWrite = false
        controller.run(file, context: context)
        await settle()
        precondition(controller.recoveryAttempts == 1 && controller.destinations.last == "search" && controller.panel.hides == 1,
                     "文件重新关联后必须继续使用搜索的目标与关闭路径")
        controller.canWrite = false
        controller.run(file, context: cancelled)
        precondition(controller.recoveryAttempts == 1, "取消关闭搜索后不能弹出文件关联窗口")
        print("Quick search paste routing passed: per-opening destination, original shelf path, cancellation, permission fallback and recovered files")
    }

    @MainActor static func settle() async {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
