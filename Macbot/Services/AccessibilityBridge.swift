import Foundation
import AppKit
import ApplicationServices

enum AccessibilityBridge {

    // MARK: - Permission

    static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Element Discovery

    /// Walk the accessibility tree of a running app to find an element by label and optional role.
    static func findElement(app appName: String, label: String, role: String? = nil) -> AXUIElement? {
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) else { return nil }

        let axApp = AXUIElementCreateApplication(runningApp.processIdentifier)
        return searchTree(root: axApp, label: label, role: role, depth: 0)
    }

    /// Recursive tree search with depth limit to avoid infinite traversal.
    private static func searchTree(root: AXUIElement, label: String, role: String?, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }

        // Check this element's title / description
        let title = stringAttribute(root, kAXTitleAttribute) ?? ""
        let desc = stringAttribute(root, kAXDescriptionAttribute) ?? ""
        let value = stringAttribute(root, kAXValueAttribute) ?? ""

        let matchesLabel = title.localizedCaseInsensitiveContains(label)
            || desc.localizedCaseInsensitiveContains(label)
            || value.localizedCaseInsensitiveContains(label)

        if matchesLabel {
            if let role {
                let elementRole = stringAttribute(root, kAXRoleAttribute) ?? ""
                if elementRole.localizedCaseInsensitiveContains(role) { return root }
            } else {
                return root
            }
        }

        // Recurse into children
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            if let found = searchTree(root: child, label: label, role: role, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - Element Position

    static func elementPosition(_ element: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        guard let posRef else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        return point
    }

    static func elementSize(_ element: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard let sizeRef else { return nil }
        var size = CGSize.zero
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return size
    }

    /// Returns the center point of an element on screen.
    static func elementCenter(_ element: AXUIElement) -> CGPoint? {
        guard let pos = elementPosition(element), let size = elementSize(element) else { return nil }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    // MARK: - Event Injection

    static func performClick(at point: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cgSessionEventTap)
        usleep(50_000) // 50ms between down/up for reliability
        up?.post(tap: .cgSessionEventTap)
    }

    static func performKeyPress(_ key: String, modifiers: CGEventFlags = []) {
        guard let (keyCode, flags) = parseKeyCombo(key, baseModifiers: modifiers) else { return }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    static func typeText(_ text: String) {
        for char in text {
            let str = String(char)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { continue }
            let chars = Array(str.utf16)
            event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            event.post(tap: .cgSessionEventTap)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.post(tap: .cgSessionEventTap)
            usleep(20_000) // 20ms per character
        }
    }

    // MARK: - Menu Navigation

    static func navigateMenu(app appName: String, path: [String]) -> Bool {
        guard let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) else { return false }

        let axApp = AXUIElementCreateApplication(runningApp.processIdentifier)

        var menuBarRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef)
        guard let menuBar = menuBarRef else { return false }

        var current: AXUIElement = menuBar as! AXUIElement
        for item in path {
            guard let found = findChild(of: current, titled: item) else { return false }
            AXUIElementPerformAction(found, kAXPressAction as CFString)
            usleep(100_000) // 100ms for menu to open
            current = found
        }
        return true
    }

    private static func findChild(of element: AXUIElement, titled title: String) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            let t = stringAttribute(child, kAXTitleAttribute) ?? ""
            if t.localizedCaseInsensitiveContains(title) { return child }

            // Also check one level deeper (menus have a submenu child)
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &subRef)
            if let subs = subRef as? [AXUIElement] {
                for sub in subs {
                    let st = stringAttribute(sub, kAXTitleAttribute) ?? ""
                    if st.localizedCaseInsensitiveContains(title) { return sub }
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func stringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
        return ref as? String
    }

    /// Parse a human-readable key combo like "Cmd+N" into (keyCode, flags).
    private static func parseKeyCombo(_ combo: String, baseModifiers: CGEventFlags) -> (CGKeyCode, CGEventFlags)? {
        let parts = combo.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var flags = baseModifiers
        var keyPart = ""

        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: keyPart = part
            }
        }

        guard let code = keyCodeMap[keyPart] else { return nil }
        return (code, flags)
    }

    private static let keyCodeMap: [String: CGKeyCode] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
        "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
        "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
        "return": 36, "enter": 36, "tab": 48, "space": 49,
        "delete": 51, "escape": 53, "esc": 53,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
    ]
}
