import Carbon
import Foundation

// Keep the TIS boundary in one executable so registration and selection can be
// recorded independently of TextEdit, event-posting permissions and the IME.
func property(_ source: TISInputSource, _ key: CFString) -> Any? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}

func describe(_ source: TISInputSource) -> [String: Any] {
    [
        "id": property(source, kTISPropertyInputSourceID) as? String ?? "",
        "bundleID": property(source, kTISPropertyBundleID) as? String ?? "",
        "type": property(source, kTISPropertyInputSourceType) as? String ?? "",
        "enabled": property(source, kTISPropertyInputSourceIsEnabled) as? Bool ?? false,
        "selectable": property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool ?? false,
        "selected": property(source, kTISPropertyInputSourceIsSelected) as? Bool ?? false
    ]
}

func sources() -> [TISInputSource] {
    TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
}

func select(_ identifier: String) -> Bool {
    guard let source = sources().first(where: {
        property($0, kTISPropertyInputSourceID) as? String == identifier
    }) else {
        printJSON(["error": "Input source not found", "id": identifier])
        return false
    }
    let alreadyEnabled = property(source, kTISPropertyInputSourceIsEnabled) as? Bool == true
    let alreadySelected = property(source, kTISPropertyInputSourceIsSelected) as? Bool == true
    var notificationObserved = false
    let center = DistributedNotificationCenter.default()
    let observer = center.addObserver(
        forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        object: nil, queue: .main
    ) { _ in notificationObserved = true }
    defer { center.removeObserver(observer) }
    let enableStatus = alreadyEnabled ? noErr : TISEnableInputSource(source)
    let selectStatus = TISSelectInputSource(source)
    // Keep the selecting process alive until the distributed change is delivered.
    // Merely reading its own TIS cache does not establish delivery to the editor.
    let notificationTimeout: TimeInterval = 5
    let deadline = Date().addingTimeInterval(notificationTimeout)
    while selectStatus == noErr && !alreadySelected && !notificationObserved && Date() < deadline {
        RunLoop.current.run(mode: .default, before: deadline)
    }
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    printJSON(["enableStatus": enableStatus, "selectStatus": selectStatus, "current": describe(current),
               "notificationObserved": notificationObserved, "alreadySelected": alreadySelected])
    return enableStatus == noErr && selectStatus == noErr
        && (alreadySelected || notificationObserved)
        && property(current, kTISPropertyInputSourceID) as? String == identifier
}

@main
enum InputSourceCommand {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "list":
            printJSON(sources().map(describe))
        case "current":
            printJSON(describe(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
        case "register" where arguments.count == 2:
            let appURL = URL(fileURLWithPath: arguments[1])
            let status = TISRegisterInputSource(appURL as CFURL)
            guard let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else {
                printJSON(["error": "The app has no bundle identifier"])
                exit(1)
            }
            let parents = sources().filter {
                property($0, kTISPropertyInputSourceID) as? String == bundleIdentifier
            }
            // The native consent applies to the parent input method. Its modes
            // already have their defaults, and requesting all modes would open
            // overlapping consent sheets instead of enabling the parent.
            var enableRecords: [[String: Any]] = []
            for source in parents {
                let enableStatus = TISEnableInputSource(source)
                enableRecords.append(["source": describe(source), "enableStatus": enableStatus])
            }
            printJSON(["registerStatus": status, "enabledSources": enableRecords])
            let enabled = !enableRecords.isEmpty && enableRecords.allSatisfy { $0["enableStatus"] as? OSStatus == noErr }
            exit(status == noErr && enabled ? 0 : 1)
        case "select" where arguments.count == 2:
            exit(select(arguments[1]) ? 0 : 1)
        case "ascii":
            let identifier = sources().compactMap { property($0, kTISPropertyInputSourceID) as? String }
                .first { $0 == "com.apple.keylayout.ABC" || $0 == "com.apple.keylayout.US" }
            guard let identifier else {
                printJSON(["error": "ABC/US keyboard layout not found"])
                exit(1)
            }
            exit(select(identifier) ? 0 : 1)
        default:
            fputs("Usage: InputSource list|current|ascii|register APP|select SOURCE_ID\n", stderr)
            exit(2)
        }
    }
}
