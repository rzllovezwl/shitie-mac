import AppKit
import Carbon
import CoreGraphics

enum PasteAvailability {
    case ready
    case needsPermission
}

enum PasteService {
    static func availability(requestPermission: Bool) -> PasteAvailability {
        if CGPreflightPostEventAccess() { return .ready }
        if requestPermission && CGRequestPostEventAccess() { return .ready }
        return .needsPermission
    }

    static func usesForegroundKeyboardStream(for bundleIdentifier: String?) -> Bool {
        switch bundleIdentifier?.lowercased() {
        case "com.tencent.xinwechat", "com.tencent.wechat": return true
        default: return false
        }
    }

    @MainActor
    static func sendPasteShortcut(to processIdentifier: pid_t,
                                  bundleIdentifier: String? = nil) -> Bool {
        guard CGPreflightPostEventAccess(),
            let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // WeChat's chat field can ignore a Quartz key pair sent directly to
        // its PID even though the same clipboard content pastes with a real
        // Command-V. Deliver the full shortcut through the active HID stream
        // only when its process is still frontmost; keep PID delivery for apps
        // whose existing behavior is already verified.
        if usesForegroundKeyboardStream(for: bundleIdentifier) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
                  NSApp.keyWindow == nil,
                  let commandDown = CGEvent(keyboardEventSource: nil,
                                            virtualKey: CGKeyCode(kVK_Command), keyDown: true),
                  let commandUp = CGEvent(keyboardEventSource: nil,
                                          virtualKey: CGKeyCode(kVK_Command), keyDown: false)
            else { return false }
            commandDown.flags = .maskCommand
            commandUp.flags = []
            commandDown.post(tap: .cghidEventTap)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            commandUp.post(tap: .cghidEventTap)
            return true
        }
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }
}
