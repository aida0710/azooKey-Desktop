import Cocoa
import InputMethodKit

final class DocumentTextInput: NSObject, IMKTextInput {
    var document = "前日本語後"
    var selection = NSRange(location: 1, length: 3)
    var marked = NSRange(location: NSNotFound, length: 0)
    var editable = true
    var readable = true
    var reportedActualRange: NSRange?
    var replacements: [String] = []

    private func replace(_ string: Any!, range: NSRange) -> NSRange? {
        guard editable else {
            return nil
        }
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        let range = range.location != NSNotFound ? range : (marked.location != NSNotFound ? marked : selection)
        guard let swiftRange = Range(range, in: document) else {
            return nil
        }
        document.replaceSubrange(swiftRange, with: text)
        replacements.append(text)
        return NSRange(location: range.location, length: text.utf16.count)
    }
    func insertText(_ string: Any!, replacementRange: NSRange) {
        guard let range = replace(string, range: replacementRange) else {
            return
        }
        marked = NSRange(location: NSNotFound, length: 0)
        selection = NSRange(location: range.location + range.length, length: 0)
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        guard let range = replace(string, range: replacementRange) else {
            return
        }
        marked = range.length == 0 ? NSRange(location: NSNotFound, length: 0) : range
        guard selectionRange.location != NSNotFound else {
            // NSTextView clamps an unspecified selection to the document end.
            selection = NSRange(location: document.utf16.count, length: 0)
            return
        }
        selection = NSRange(location: range.location + selectionRange.location, length: selectionRange.length)
    }
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { marked }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle rect: NSRectPointer!) -> [AnyHashable: Any]! { [:] }
    func length() -> Int { document.utf16.count }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        guard readable, let swiftRange = Range(range, in: document) else {
            return nil
        }
        actualRange?.pointee = reportedActualRange ?? range
        return String(document[swiftRange])
    }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "azookey-tests-document-client" }
    func windowLevel() -> CGWindowLevel { 0 }
    func bundleIdentifier() -> String! { "azookey.tests.document" }
}
