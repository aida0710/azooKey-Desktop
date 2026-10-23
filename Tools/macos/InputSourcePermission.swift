import AppKit
import ApplicationServices

// Capture the Keyboard settings sheet opened by TISEnableInputSource, including
// any native confirmation prompt, without changing the runner's privacy database.
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

@main
enum InputSourcePermissionCommand {
    static func main() {
        let settingsApplications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
        var pending = settingsApplications.flatMap { application in
            attribute(AXUIElementCreateApplication(application.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        }
        var entries: [[String: String]] = []
        // A Settings window has a finite tree; bound malformed accessibility providers.
        let maximumElementCount = 1000
        while !pending.isEmpty && entries.count < maximumElementCount {
            let element = pending.removeFirst()
            var entry: [String: String] = [:]
            for name in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute] {
                if let value = attribute(element, name) as? String { entry[name] = value }
            }
            entries.append(entry)
            pending.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        printJSON(entries)
    }
}
