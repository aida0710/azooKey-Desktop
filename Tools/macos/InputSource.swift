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

func emit(_ value: Any) {
    let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: bytes, as: UTF8.self))
}

func select(_ identifier: String) -> Bool {
    guard let source = sources().first(where: {
        property($0, kTISPropertyInputSourceID) as? String == identifier
    }) else {
        emit(["error": "Input source not found", "id": identifier])
        return false
    }
    let enableStatus = TISEnableInputSource(source)
    let selectStatus = TISSelectInputSource(source)
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    emit(["enableStatus": enableStatus, "selectStatus": selectStatus, "current": describe(current)])
    return enableStatus == noErr && selectStatus == noErr
        && property(current, kTISPropertyInputSourceID) as? String == identifier
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "list":
    emit(sources().map(describe))
case "current":
    emit(describe(TISCopyCurrentKeyboardInputSource().takeRetainedValue()))
case "register" where arguments.count == 2:
    let status = TISRegisterInputSource(URL(fileURLWithPath: arguments[1]) as CFURL)
    emit(["registerStatus": status])
    exit(status == noErr ? 0 : 1)
case "select" where arguments.count == 2:
    exit(select(arguments[1]) ? 0 : 1)
case "ascii":
    let identifier = sources().compactMap { property($0, kTISPropertyInputSourceID) as? String }
        .first { $0 == "com.apple.keylayout.ABC" || $0 == "com.apple.keylayout.US" }
    guard let identifier else {
        emit(["error": "ABC/US keyboard layout not found"])
        exit(1)
    }
    exit(select(identifier) ? 0 : 1)
default:
    fputs("Usage: InputSource list|current|ascii|register APP|select SOURCE_ID\n", stderr)
    exit(2)
}
