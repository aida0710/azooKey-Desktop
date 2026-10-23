import AppKit
import ApplicationServices

// Reading the actual focused text area avoids AppleEvent startup timeouts on
// hosted runners. Only clear uses AX to change text; the test uses physical keys.
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func emit(_ value: [String: Any]) {
    let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: bytes, as: UTF8.self))
}

let command = CommandLine.arguments.dropFirst().first ?? "read"
guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
    emit(["error": "TextEdit is not running"])
    exit(1)
}
guard AXIsProcessTrusted() else {
    emit(["error": "Accessibility permission is required to inspect TextEdit"])
    exit(3)
}
let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
guard let focusedValue = attribute(applicationElement, kAXFocusedUIElementAttribute),
      CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
    emit(["error": "TextEdit has no focused accessibility element"])
    exit(1)
}
let focusedElement = focusedValue as! AXUIElement
let role = attribute(focusedElement, kAXRoleAttribute) as? String ?? ""
guard role == kAXTextAreaRole else {
    emit(["error": "The focused element is not a document text area", "role": role])
    exit(1)
}
switch command {
case "clear":
    let status = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, "" as CFString)
    emit(["clearStatus": status.rawValue])
    exit(status == .success ? 0 : 1)
case "read":
    guard let text = attribute(focusedElement, kAXValueAttribute) as? String else {
        emit(["error": "Cannot read the document value"])
        exit(1)
    }
    emit(["text": text, "role": role,
          "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit"])
default:
    emit(["error": "Usage: TextEditDocument read|clear"])
    exit(2)
}
