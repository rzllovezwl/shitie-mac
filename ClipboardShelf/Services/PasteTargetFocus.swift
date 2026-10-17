import ApplicationServices
import Foundation

/// Holds only an Accessibility element identity, never the element's contents.
/// If an app does not expose its focused element, automatic paste is skipped.
struct PasteTargetFocus {
    let processIdentifier: pid_t
    private let element: AXUIElement

    static func capture(for processIdentifier: pid_t) -> PasteTargetFocus? {
        guard let element = focusedElement(in: processIdentifier) else { return nil }
        return PasteTargetFocus(processIdentifier: processIdentifier, element: element)
    }

    func stillMatches() -> Bool {
        guard let current = Self.focusedElement(in: processIdentifier) else { return false }
        return CFEqual(element, current)
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
