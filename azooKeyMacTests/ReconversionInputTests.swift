import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@testable import azooKeyMac

private final class ReconversionTextInput: NSObject, IMKTextInput {
    var document = "前日本語後"
    var selection = NSRange(location: 1, length: 3)
    var marked = NSRange(location: NSNotFound, length: 0)
    var editable = true
    var readable = true
    var replacements: [String] = []

    private func replace(_ string: Any!, range: NSRange) -> NSRange? {
        guard editable else { return nil }
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        let range = range.location != NSNotFound ? range : (marked.location != NSNotFound ? marked : selection)
        guard let swiftRange = Range(range, in: document) else { return nil }
        document.replaceSubrange(swiftRange, with: text)
        replacements.append(text)
        return NSRange(location: range.location, length: text.utf16.count)
    }
    func insertText(_ string: Any!, replacementRange: NSRange) {
        guard let range = replace(string, range: replacementRange) else { return }
        marked = NSRange(location: NSNotFound, length: 0)
        selection = NSRange(location: range.location + range.length, length: 0)
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        guard let range = replace(string, range: replacementRange) else { return }
        marked = range.length == 0 ? NSRange(location: NSNotFound, length: 0) : range
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
        guard readable, let swiftRange = Range(range, in: document) else { return nil }
        actualRange?.pointee = range
        return String(document[swiftRange])
    }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "azookey-tests-reconversion-client" }
    func windowLevel() -> CGWindowLevel { 0 }
    func bundleIdentifier() -> String! { "azookey.tests.reconversion" }
}

@MainActor
final class ReconversionInputTests: XCTestCase {
    private var manager: SegmentsManager!
    private var session: MacReconversionSession!
    private var client: ReconversionTextInput!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
                                  containerURL: nil, context: .init(useZenzai: false))
        session = MacReconversionSession()
        session.isSensitive = { false }
        client = ReconversionTextInput()
    }

    override func tearDown() {
        manager = nil
        session = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testSelectionReconversionReplacesTheExactRangeAndCancelRestoresItOnce() throws {
        let replacement = try session.prepare(undo: false, client: client, reading: "にほんご")
        try session.apply(replacement, client: client, manager: manager)
        XCTAssertEqual(client.document, "前にほんご後")
        XCTAssertEqual(manager.convertTarget, "にほんご")
        session.restoreOriginal(client: client)
        session.restoreOriginal(client: client)
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertEqual(client.replacements, ["にほんご", "日本語"])
    }

    func testCommitUndoRestoresTheRawInputWithoutDuplicatingDocumentText() throws {
        client.document = "前後"
        client.selection = NSRange(location: 1, length: 0)
        manager.insertAtCursorPosition("nihongo", inputStyle: .mapped(id: .defaultRomanToKana))
        client.setMarkedText("にほんご", selectionRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let source = session.captureCommit(from: manager, client: client)
        client.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        manager.stopComposition()
        session.rememberCommit(source, manager: manager, client: client)
        let replacement = try session.prepare(undo: true, client: client, reading: nil)
        try session.apply(replacement, client: client, manager: manager)
        XCTAssertEqual(client.document, "前にほんご後")
        XCTAssertEqual(manager.getModifiedRomanCandidate(inputState: .composing) { $0 }.text, "nihongo")
    }

    func testReadonlyOrUnreadableClientsDoNotLoseTheSelection() throws {
        client.editable = false
        let replacement = try session.prepare(undo: false, client: client, reading: "にほんご")
        XCTAssertThrowsError(try session.apply(replacement, client: client, manager: manager))
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertTrue(manager.isEmpty)
        client.readable = false
        XCTAssertThrowsError(try session.prepare(undo: false, client: client, reading: "にほんご"))
        XCTAssertTrue(client.replacements.isEmpty)
    }

    func testChangedSelectionFocusAndSensitiveFieldsRejectPreparedReplacement() throws {
        let replacement = try session.prepare(undo: false, client: client, reading: "にほんご")
        let otherClient = ReconversionTextInput()
        XCTAssertThrowsError(try session.apply(replacement, client: otherClient, manager: manager))
        XCTAssertTrue(otherClient.replacements.isEmpty)
        client.document = "別日本語後"
        XCTAssertThrowsError(try session.apply(replacement, client: client, manager: manager))
        XCTAssertTrue(client.replacements.isEmpty)
        client.document = "前日本語後"
        session.clear()
        XCTAssertThrowsError(try session.apply(replacement, client: client, manager: manager))
        session.isSensitive = { true }
        XCTAssertThrowsError(try session.prepare(undo: false, client: client, reading: "にほんご"))
        XCTAssertTrue(client.replacements.isEmpty)
    }

    func testNonBMPAndCombiningTextUseUTF16ReplacementRanges() throws {
        client.document = "👩‍💻e\u{301}後"
        client.selection = NSRange(location: 0, length: 7)
        let replacement = try session.prepare(undo: false, client: client, reading: "えもじ")
        XCTAssertEqual(replacement.count, 5)
        try session.apply(replacement, client: client, manager: manager)
        XCTAssertEqual(client.document, "えもじ後")
        session.restoreOriginal(client: client)
        XCTAssertEqual(client.document, "👩‍💻e\u{301}後")
    }
}
