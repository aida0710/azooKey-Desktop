import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func descendants(_ roots: [AXUIElement]) -> [AXUIElement] {
    var pending = roots
    var elements: [AXUIElement] = []
    // A Settings window has a finite tree; bound malformed accessibility providers.
    let maximumElementCount = 1000
    while !pending.isEmpty && elements.count < maximumElementCount {
        let element = pending.removeFirst()
        elements.append(element)
        pending.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return elements
}

func describe(_ element: AXUIElement) -> [String: String] {
    var entry: [String: String] = [:]
    for name in [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute] {
        if let value = attribute(element, name) as? String { entry[name] = value }
    }
    return entry
}

func approveAzooKey(_ elements: [AXUIElement]) {
    // The user explicitly requested enabling this IME on a disposable runner.
    // Match both our requesting executable and the azooKey input source inside
    // the same sheet; never approve unrelated Settings or privacy prompts.
    for sheet in elements where attribute(sheet, kAXRoleAttribute) as? String == kAXSheetRole {
        let children = descendants([sheet])
        let prompt = children.compactMap { attribute($0, kAXValueAttribute) as? String }.first {
            $0.hasPrefix("Allow “InputSource” to enable “azooKey") && $0.hasSuffix("”?")
        }
        guard let prompt else { continue }
        guard let button = children.first(where: {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole
                && attribute($0, kAXIdentifierAttribute) as? String == "action-button-1"
                && attribute($0, kAXDescriptionAttribute) as? String == "Allow"
        }) else { continue }
        let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
        printJSON(["matchedPrompt": prompt, "pressStatus": status.rawValue])
        exit(status == .success ? 0 : 1)
    }
    printJSON(["matchedPrompt": false])
}

@main
enum InputSourcePermissionCommand {
    static func main() {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
        let windows = applications.flatMap { application in
            attribute(AXUIElementCreateApplication(application.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        }
        let elements = descendants(windows)
        switch CommandLine.arguments.dropFirst().first ?? "inspect" {
        case "inspect": printJSON(elements.map(describe))
        case "approve": approveAzooKey(elements)
        default:
            fputs("Usage: InputSourcePermission inspect|approve\n", stderr)
            exit(2)
        }
    }
}
