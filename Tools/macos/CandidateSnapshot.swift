import AppKit
import ApplicationServices

func candidateAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func candidateElement(_ element: AXUIElement, depth: Int = 0) -> [String: Any] {
    var description: [String: Any] = [:]
    for name in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                 kAXIdentifierAttribute, kAXSelectedAttribute, kAXHelpAttribute] {
        if let value = candidateAttribute(element, name), value is String || value is NSNumber {
            description[name] = value
        }
    }
    for name in [kAXPositionAttribute, kAXSizeAttribute] {
        guard let value = candidateAttribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { continue }
        let geometry = value as! AXValue
        if name == kAXPositionAttribute {
            var point = CGPoint.zero
            if AXValueGetValue(geometry, .cgPoint, &point) { description[name] = [point.x, point.y] }
        } else {
            var size = CGSize.zero
            if AXValueGetValue(geometry, .cgSize, &size) { description[name] = [size.width, size.height] }
        }
    }
    // Bound inspection even if an application accidentally exposes a cyclic tree.
    let maximumDepth = 20
    if depth < maximumDepth {
        let children = candidateAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        description["children"] = children.map { candidateElement($0, depth: depth + 1) }
    }
    return description
}

@main
enum CandidateSnapshotCommand {
    static func main() {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.ensan.inputmethod.azooKeyMac").first else {
            printJSON(["error": "The running IME and Accessibility permission are required"])
            exit(1)
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let windows = candidateAttribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let screens = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        printJSON(["windows": windows.map { candidateElement($0) },
                   "screenWindows": screens.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) },
                   "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""])
    }
}
