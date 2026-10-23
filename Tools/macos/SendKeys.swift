import AppKit
import ApplicationServices
import Metal

let command = CommandLine.arguments.dropFirst().first ?? "permissions"
if command == "permissions" {
    let permissions: [String: Any] = [
        "accessibilityTrusted": AXIsProcessTrusted(),
        "postEventAccess": CGPreflightPostEventAccess(),
        "screenCaptureAccess": CGPreflightScreenCaptureAccess(),
        "metalDevices": MTLCopyAllDevices().map { $0.name },
        "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    ]
    let bytes = try! JSONSerialization.data(withJSONObject: permissions, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: bytes, as: UTF8.self))
    exit(0)
}

guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
    fputs("TextEdit is not frontmost; no events were posted.\n", stderr)
    exit(1)
}
guard CGPreflightPostEventAccess() else {
    fputs("CGEvent posting denied: the runner needs Accessibility/PostEvent permission. No permission prompt was opened.\n", stderr)
    exit(3)
}

let keyCodes: [CGKeyCode]
var modifiers: CGEventFlags = []
switch command {
case "nihongo": keyCodes = [45, 34, 4, 31, 45, 5, 31]
case "space": keyCodes = [49]
case "return": keyCodes = [36]
case "save":
    keyCodes = [1]
    modifiers = .maskCommand
default:
    fputs("Usage: SendKeys permissions|nihongo|space|return|save\n", stderr)
    exit(2)
}

// Deliberately pace physical key down/up events. Unicode insertion would bypass
// the input method and could make a broken IME look healthy.
let keyHoldInterval: TimeInterval = 0.04
let interKeyInterval: TimeInterval = 0.15
let source = CGEventSource(stateID: .hidSystemState)
for keyCode in keyCodes {
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        fputs("Unable to create a keyboard event.\n", stderr)
        exit(1)
    }
    down.flags = modifiers
    up.flags = modifiers
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: keyHoldInterval)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: interKeyInterval)
}
print("Posted \(keyCodes.count) physical keys: \(command)")
