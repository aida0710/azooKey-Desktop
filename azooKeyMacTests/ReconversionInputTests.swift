import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@testable import azooKeyMac

@MainActor
final class ReconversionInputTests: XCTestCase {
    private var manager: SegmentsManager!
    private var session: MacReconversionSession!
    private var client: DocumentTextInput!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
                                  containerURL: nil, context: .init(useZenzai: false))
        session = MacReconversionSession()
        session.isSensitive = { false }
        client = DocumentTextInput()
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
        let otherClient = DocumentTextInput()
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
