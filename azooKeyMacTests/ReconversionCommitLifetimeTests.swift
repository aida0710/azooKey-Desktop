import Cocoa
import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@testable import azooKeyMac

@MainActor
final class ReconversionCommitLifetimeTests: XCTestCase {
    private var manager: SegmentsManager!
    private var session: MacReconversionSession!
    private var client: DocumentTextInput!
    private var controller: azooKeyMacInputController?
    private var serverFixture: InputMethodTestServer?
    private var directory: URL!
    private var restoreSettings: (() -> Void)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        let oldLive = Config.LiveConversion().value
        let oldTree = Config.TreeCandidates().value
        let oldInputStyle = Config.InputStyle().value
        restoreSettings = {
            Config.LiveConversion().value = oldLive
            Config.TreeCandidates().value = oldTree
            Config.InputStyle().value = oldInputStyle
        }
        Config.LiveConversion().value = false
        Config.TreeCandidates().value = false
        Config.InputStyle().value = .default
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
            containerURL: nil, context: .init(useZenzai: false)
        )
        manager.learningEnabled = false
        session = MacReconversionSession()
        session.isSensitive = { false }
        client = DocumentTextInput()
    }

    override func tearDown() {
        controller?.cancelReplaceSuggestion()
        controller = nil
        serverFixture = nil
        session = nil
        manager = nil
        client = nil
        restoreSettings?()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    private func reconvertSelection() throws {
        let replacement = try session.prepare(undo: false, client: client, reading: "にほんご")
        try session.apply(replacement, client: client, manager: manager)
        XCTAssertEqual(session.originalText, "日本語")
    }

    private func appendAndCancelNewMarkedText() {
        manager.insertAtCursorPosition("a", inputStyle: .mapped(id: .defaultRomanToKana))
        client.setMarkedText("あ", selectionRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        session.beginInput()
        let countBeforeCancel = client.replacements.count
        session.restoreOriginal(client: client)
        XCTAssertEqual(client.replacements.count, countBeforeCancel)
        manager.stopComposition()
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func testCommittingBeforeTheNextCompositionRetiresItsOriginalWithoutRecordingHistory() throws {
        try reconvertSelection()
        let source = try XCTUnwrap(session.captureCommit(from: manager, client: client))
        session.commitText("日本語", client: client)
        manager.stopComposition()
        manager.insertAtCursorPosition("a", inputStyle: .mapped(id: .defaultRomanToKana))
        session.rememberCommit(source, manager: manager, client: client)
        XCTAssertFalse(manager.isEmpty)
        XCTAssertNil(session.originalText)
        manager.stopComposition()
        appendAndCancelNewMarkedText()
        XCTAssertEqual(client.document, "前日本語後")
    }

    private func commitWithUnavailableHistory(captureIsReadable: Bool) throws {
        try reconvertSelection()
        client.readable = captureIsReadable
        let source = session.captureCommit(from: manager, client: client)
        XCTAssertEqual(source != nil, captureIsReadable)
        session.commitText("日本語", client: client)
        manager.stopComposition()
        client.readable = false
        session.rememberCommit(source, manager: manager, client: client)
        XCTAssertNil(session.originalText)
        client.readable = true
        XCTAssertThrowsError(try session.prepare(undo: true, client: client, reading: nil))
        appendAndCancelNewMarkedText()
        XCTAssertEqual(client.document, "前日本語後")
    }

    func testMissingCommitSourceCannotRestoreAnOldOriginalIntoLaterInput() throws {
        try commitWithUnavailableHistory(captureIsReadable: false)
    }

    func testUnreadableCommitHistoryCannotRestoreAnOldOriginalIntoLaterInput() throws {
        try commitWithUnavailableHistory(captureIsReadable: true)
    }

    func testRetiringTheOriginalStillAllowsTheNewCommitToBeUndone() throws {
        try reconvertSelection()
        let source = try XCTUnwrap(session.captureCommit(from: manager, client: client))
        session.commitText("別表記", client: client)
        manager.stopComposition()
        session.rememberCommit(source, manager: manager, client: client)
        XCTAssertNil(session.originalText)
        let replacement = try session.prepare(undo: true, client: client, reading: nil)
        XCTAssertEqual(replacement.text, "別表記")
        try session.apply(replacement, client: client, manager: manager)
        XCTAssertEqual(manager.convertTarget, "にほんご")
        session.restoreOriginal(client: client)
        XCTAssertEqual(client.document, "前別表記後")
    }

    private func makeReconversionController() throws -> azooKeyMacInputController {
        serverFixture = try InputMethodTestServer(
            directoryURL: directory, controllerClass: InputMethodTestController.self
        )
        let controller = try XCTUnwrap(InputMethodTestController(
            server: try XCTUnwrap(serverFixture?.server), client: client, segmentsManager: manager
        ))
        XCTAssertTrue(controller.client() === client)
        self.controller = controller
        controller.reconversionClient = session
        controller.requestReconversion(undo: false, reading: "にほんご", client: client)
        XCTAssertEqual(controller.inputState, .selecting)
        XCTAssertEqual(session.originalText, "日本語")
        return controller
    }

    private func send(_ action: UserAction, to controller: azooKeyMacInputController) {
        let (clientAction, callback) = controller.inputState.event(
            eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0),
            userAction: action, inputLanguage: .japanese,
            liveConversionEnabled: false, enableDebugWindow: false, enableSuggestion: false
        )
        XCTAssertTrue(controller.handleClientAction(clientAction, clientActionCallback: callback, client: client))
    }

    private func markedText() throws -> String {
        let range = try XCTUnwrap(Range(client.marked, in: client.document))
        return String(client.document[range])
    }

    private func cancelNextInput(_ controller: azooKeyMacInputController, committedText: String) {
        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertEqual(manager.convertTarget, "あ")
        XCTAssertEqual(client.document, "前\(committedText)あ後")
        send(.escape, to: controller)
        XCTAssertEqual(client.document, "前\(committedText)後")
        XCTAssertEqual(controller.inputState, .none)
        XCTAssertTrue(manager.isEmpty)
        XCTAssertNil(session.originalText)
    }

    func testTypingAfterAReconversionAndCancelingKeepsOnlyTheCommittedText() throws {
        let controller = try makeReconversionController()
        let committedText = try markedText()
        send(.input([.character("a")]), to: controller)
        cancelNextInput(controller, committedText: committedText)
    }

    func testCommitAndAppendStringAlsoRetiresThePreviousOriginal() throws {
        let controller = try makeReconversionController()
        let committedText = try markedText()
        XCTAssertTrue(controller.handleClientAction(
            .commitMarkedTextAndAppendToMarkedText("a"), clientActionCallback: .transition(.composing), client: client
        ))
        cancelNextInput(controller, committedText: committedText)
    }

    func testCandidateCommitWithUnreadableHistoryDoesNotAffectTheNextCancel() throws {
        let controller = try makeReconversionController()
        let committedText = try markedText()
        client.readable = false
        send(.enter, to: controller)
        XCTAssertTrue(manager.isEmpty)
        XCTAssertNil(session.originalText)
        client.readable = true
        send(.input([.character("a")]), to: controller)
        cancelNextInput(controller, committedText: committedText)
    }

    func testInputMethodCommitDoesNotRestoreTheOldOriginalIntoTheNextInput() throws {
        let controller = try makeReconversionController()
        let committedText = try markedText()
        controller.commitComposition(client)
        XCTAssertNil(session.originalText)
        send(.input([.character("a")]), to: controller)
        cancelNextInput(controller, committedText: committedText)
    }

    func testCancelingBeforeCommitStillRestoresTheOriginalSelection() throws {
        let controller = try makeReconversionController()
        send(.escape, to: controller)
        send(.escape, to: controller)
        send(.escape, to: controller)
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertEqual(controller.inputState, .none)
        XCTAssertTrue(manager.isEmpty)
        let countAfterCancel = client.replacements.count
        session.restoreOriginal(client: client)
        XCTAssertEqual(client.replacements.count, countAfterCancel)
    }
}
