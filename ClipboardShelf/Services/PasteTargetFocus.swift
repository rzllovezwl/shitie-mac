import ApplicationServices
import CoreGraphics
import Foundation

/// Holds only an Accessibility element identity, never the element's contents.
struct PasteTargetFocus {
    let processIdentifier: pid_t
    private let element: AXUIElement

    enum Match {
        case matches, changed, unavailable
    }

    static func capture(for processIdentifier: pid_t) -> PasteTargetFocus? {
        guard let element = focusedElement(in: processIdentifier) else { return nil }
        return PasteTargetFocus(processIdentifier: processIdentifier, element: element)
    }

    func matchState() -> Match {
        guard let current = Self.focusedElement(in: processIdentifier) else { return .unavailable }
        return CFEqual(element, current) ? .matches : .changed
    }

    private static func focusedElement(in processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXFocusedUIElementAttribute as CFString, &value
        ) == .success, let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
              owner == processIdentifier else { return nil }
        return element
    }
}

/// A window identity is a fallback when an app does not expose its focused AX element.
/// The window list does not read the window's title or contents.
struct PasteTargetWindow {
    let processIdentifier: pid_t
    let windowNumber: CGWindowID

    static func capture(for processIdentifier: pid_t) -> PasteTargetWindow? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]],
        let windowNumber = frontWindowNumber(in: windows, ownedBy: processIdentifier) else { return nil }
        return PasteTargetWindow(processIdentifier: processIdentifier, windowNumber: windowNumber)
    }

    func stillMatches() -> Bool {
        Self.capture(for: processIdentifier)?.windowNumber == windowNumber
    }

    static func frontWindowNumber(in windows: [[String: Any]], ownedBy processIdentifier: pid_t) -> CGWindowID? {
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  number.uint32Value != 0 else { continue }
            return number.uint32Value
        }
        return nil
    }
}

struct PasteTargetSnapshot {
    let processIdentifier: pid_t
    private let focus: PasteTargetFocus?
    private let window: PasteTargetWindow?

    static func capture(for processIdentifier: pid_t) -> PasteTargetSnapshot? {
        let focus = PasteTargetFocus.capture(for: processIdentifier)
        let window = PasteTargetWindow.capture(for: processIdentifier)
        guard focus != nil || window != nil else { return nil }
        return PasteTargetSnapshot(processIdentifier: processIdentifier, focus: focus, window: window)
    }

    func stillMatches() -> Bool {
        if let focus {
            switch focus.matchState() {
            case .matches: return true
            case .changed: return false
            case .unavailable: break
            }
        }
        return window?.stillMatches() == true
    }
}
