import Carbon
import CoreGraphics

enum PasteAvailability {
    case ready
    case needsPermission
    case appStoreBuild
}

enum PasteService {
    static func availability(requestPermission: Bool) -> PasteAvailability {
        #if APP_STORE
        return .appStoreBuild
        #else
        if CGPreflightPostEventAccess() { return .ready }
        if requestPermission && CGRequestPostEventAccess() { return .ready }
        return .needsPermission
        #endif
    }

    static func sendPasteShortcut(to processIdentifier: pid_t) -> Bool {
        #if APP_STORE
        return false
        #else
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
        #endif
    }
}
