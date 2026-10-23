import AppKit
import ApplicationServices

// Reading the actual focused text area avoids AppleEvent startup timeouts on
// hosted runners. Only clear uses AX to change text; the test uses physical keys.
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func documentTextArea(_ application: AXUIElement) -> AXUIElement? {
    if let focused = attribute(application, kAXFocusedUIElementAttribute),
       CFGetTypeID(focused) == AXUIElementGetTypeID(),
       attribute(focused as! AXUIElement, kAXRoleAttribute) as? String == kAXTextAreaRole {
        return (focused as! AXUIElement)
    }
    // Spelling suggestions can temporarily own focus. The main document's
    // text area remains readable through the window's accessibility tree.
    guard let window = attribute(application, kAXMainWindowAttribute),
          CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
    var pending = [window as! AXUIElement]
    while !pending.isEmpty {
        let element = pending.removeFirst()
        if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole { return element }
        pending.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return nil
}

// An editor already active during an external TIS selection can retain its old
// input context. Wait for both focus changes instead of delaying key delivery.
func activateAndWait(_ application: NSRunningApplication) -> Bool {
    guard application.activate(options: [.activateIgnoringOtherApps]) else { return false }
    let activationTimeout: TimeInterval = 5
    let deadline = Date().addingTimeInterval(activationTimeout)
    let activationPollInterval: TimeInterval = 0.05
    while Date() < deadline {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            return true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(activationPollInterval))
    }
    return false
}

@main
enum TextEditDocumentCommand {
    static func main() {
        let command = CommandLine.arguments.dropFirst().first ?? "read"
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            printJSON(["error": "TextEdit is not running"])
            exit(1)
        }
        guard AXIsProcessTrusted() else {
            printJSON(["error": "Accessibility permission is required to inspect TextEdit"])
            exit(3)
        }
        if command == "reactivate" {
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                  activateAndWait(finder), activateAndWait(application) else {
                printJSON(["error": "Could not reactivate TextEdit after input source selection"])
                exit(1)
            }
            printJSON(["frontmost": true])
            exit(0)
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let focusedElement = documentTextArea(applicationElement) else {
            printJSON(["error": "Cannot find TextEdit's document text area"])
            exit(1)
        }
        let role = kAXTextAreaRole
        switch command {
        case "clear":
            let status = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, "" as CFString)
            printJSON(["clearStatus": status.rawValue])
            exit(status == .success ? 0 : 1)
        case "read":
            guard let text = attribute(focusedElement, kAXValueAttribute) as? String else {
                printJSON(["error": "Cannot read the document value"])
                exit(1)
            }
            printJSON(["text": text, "role": role,
                  "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit"])
        default:
            printJSON(["error": "Usage: TextEditDocument read|clear|reactivate"])
            exit(2)
        }
    }
}
