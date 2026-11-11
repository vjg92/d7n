import AppKit
import ApplicationServices
import Carbon

struct InsertionTarget {
    let pid: pid_t
    /// nil when the app (e.g. VS Code / Electron) does not expose its focused element.
    /// Text is then typed into `pid` with keyboard events.
    let element: AXUIElement?

    static func capture() -> InsertionTarget? {
        guard !IsSecureEventInputEnabled() else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        // System-wide focus finds panels that are not the frontmost app, such as Spotlight.
        if let (pid, element) = systemFocus() {
            guard pid != own else { return nil }
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            guard subrole as? String != "AXSecureTextField" else { return nil }
            return InsertionTarget(pid: pid, element: element)
        }
        // Electron apps often report no focused element; fall back to the frontmost app.
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own else { return nil }
        return InsertionTarget(pid: app.processIdentifier, element: nil)
    }

    private static func systemFocus() -> (pid_t, AXUIElement)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return (pid, element)
    }

    func stillFocused() -> Bool {
        guard let current = Self.capture() else { return false }
        guard current.pid == pid else { return false }
        if let element, let now = current.element { return CFEqual(now, element) }
        return element == nil && current.element == nil
    }

    private func selectionLocation() -> Int? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// No clipboard access. Prefer replacing the current selection through AX.
    func insert(_ text: String) -> Bool {
        guard stillFocused(), !text.isEmpty else { return false }
        if let element {
            let before = selectionLocation()
            if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
                // Some apps report success without inserting; trust it only if the caret moved (or can't be read).
                guard let before, let after = selectionLocation() else { return true }
                if after != before { return true }
            }
        }
        // Unicode keyboard events: used for Electron apps and as a fallback.
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        var chunk = ""
        func send(_ chunk: String) -> Bool {
            guard stillFocused(), let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            let units = Array(chunk.utf16)
            down.flags = []; up.flags = []
            units.withUnsafeBufferPointer { ptr in
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: ptr.baseAddress)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: ptr.baseAddress)
            }
            down.postToPid(pid); up.postToPid(pid)
            return true
        }
        for scalar in text.unicodeScalars {
            if chunk.utf16.count + scalar.utf16.count > 20 { guard send(chunk) else { return false }; chunk = "" }
            chunk.unicodeScalars.append(scalar)
        }
        return chunk.isEmpty || send(chunk)
    }
}
