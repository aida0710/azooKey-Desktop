import Cocoa

// Each invocation has a fresh native text view and only fixed, synthetic text.
// This observes NSTextView; it does not implement the DocumentTextInput fixture.
let scenario = CommandLine.arguments.dropFirst().first ?? "sentinel-both"
let noReplacement = NSRange(location: NSNotFound, length: 0)
let noSelection = NSRange(location: NSNotFound, length: NSNotFound)
let application = NSApplication.shared
let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
textView.isRichText = false
textView.string = "前日本語後"
textView.setSelectedRange(NSRange(location: 1, length: 3))

func rangeFields(_ range: NSRange) -> [String: Any] {
    [
        "location": range.location,
        "length": range.length,
        "locationIsNotFound": range.location == NSNotFound,
        "lengthIsNotFound": range.length == NSNotFound
    ]
}

func record(_ step: String, request: [String: Any] = [:]) throws {
    let observation: [String: Any] = [
        "scenario": scenario,
        "step": step,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "document": textView.string,
        "documentUTF16Length": textView.string.utf16.count,
        "selectedRange": rangeFields(textView.selectedRange()),
        "markedRange": rangeFields(textView.markedRange()),
        "hasMarkedText": textView.hasMarkedText(),
        "request": request
    ]
    let json = try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func mark(_ text: String, selection: NSRange, step: String) throws {
    let request: [String: Any] = [
        "operation": "setMarkedText",
        "text": text,
        "selectionRange": rangeFields(selection),
        "replacementRange": rangeFields(noReplacement)
    ]
    try record("\(step)-before", request: request)
    textView.setMarkedText(
        NSAttributedString(string: text),
        selectedRange: selection,
        replacementRange: noReplacement
    )
    try record("\(step)-after", request: request)
}

func commit(_ text: String, step: String) throws {
    let request: [String: Any] = [
        "operation": "insertText",
        "text": text,
        "replacementRange": rangeFields(noReplacement)
    ]
    try record("\(step)-before", request: request)
    textView.insertText(text, replacementRange: noReplacement)
    try record("\(step)-after", request: request)
}

try record("initial")
switch scenario {
case "sentinel-both":
    try mark("にほんご", selection: noSelection, step: "preview")
case "sentinel-location":
    try mark("にほんご", selection: noReplacement, step: "preview")
case "preview-then-clear":
    try mark("日本語", selection: NSRange(location: 3, length: 0), step: "conversion")
    try mark("にほんご", selection: noSelection, step: "preview")
    try mark("", selection: noSelection, step: "clear")
    try mark("あ", selection: NSRange(location: 1, length: 0), step: "next-input")
case "commit-then-empty":
    try commit("日本語", step: "commit")
    try mark("", selection: noSelection, step: "empty-refresh")
    try mark("あ", selection: NSRange(location: 1, length: 0), step: "next-input")
case "valid-preview-then-clear":
    try mark("日本語", selection: NSRange(location: 3, length: 0), step: "conversion")
    try mark("にほんご", selection: NSRange(location: 4, length: 0), step: "preview")
    try mark("", selection: NSRange(location: 0, length: 0), step: "clear")
    try mark("あ", selection: NSRange(location: 1, length: 0), step: "next-input")
case "valid-commit-then-empty":
    try commit("日本語", step: "commit")
    try mark("", selection: NSRange(location: 0, length: 0), step: "empty-refresh")
    try mark("あ", selection: NSRange(location: 1, length: 0), step: "next-input")
case "selected-range":
    try mark("にほんご", selection: NSRange(location: 1, length: 2), step: "selection")
case "unicode-range":
    textView.string = "😀前日本語後"
    textView.setSelectedRange(NSRange(location: 3, length: 3))
    try record("unicode-initial")
    try mark("か\u{3099}😀", selection: NSRange(location: 2, length: 2), step: "selection")
case "sentinel-at-zero":
    textView.setSelectedRange(NSRange(location: 0, length: 1))
    try record("zero-initial")
    try mark("先", selection: noSelection, step: "preview")
default:
    FileHandle.standardError.write(Data("Unknown scenario: \(scenario)\n".utf8))
    exit(2)
}
