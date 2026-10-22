import Cocoa
import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@testable import azooKeyMac

@MainActor
final class MarkedTextSelectionTests: XCTestCase {
    private func withController(
        _ operation: (InputMethodTestController, DocumentTextInput) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let oldLive = Config.LiveConversion().value
        let oldTree = Config.TreeCandidates().value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            Config.LiveConversion().value = oldLive
            Config.TreeCandidates().value = oldTree
            try? FileManager.default.removeItem(at: directory)
        }
        Config.LiveConversion().value = false
        Config.TreeCandidates().value = false
        let manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
            containerURL: nil, context: .init(useZenzai: false)
        )
        manager.learningEnabled = false
        let client = DocumentTextInput()
        client.document = "前後"
        client.selection = NSRange(location: 1, length: 0)
        let serverFixture = try InputMethodTestServer.shared
        let controller = try XCTUnwrap(InputMethodTestController(
            server: serverFixture.server, client: client, segmentsManager: manager
        ))
        defer { controller.cancelReplaceSuggestion() }
        try operation(controller, client)
    }

    private func insertMarkedText(_ text: String, state: InputState, controller: InputMethodTestController) {
        controller.segmentsManager.insertAtCursorPosition(text, inputStyle: .direct)
        controller.inputState = state
        controller.refreshMarkedText()
    }

    func testAnEmptyRefreshAfterCommitKeepsTheNextInputBeforeTheSuffix() throws {
        try withController { controller, client in
            insertMarkedText("あ", state: .composing, controller: controller)
            controller.commitComposition(client)
            XCTAssertEqual(client.document, "前あ後")
            XCTAssertEqual(client.selectedRange(), NSRange(location: 2, length: 0))
            XCTAssertTrue(controller.segmentsManager.isEmpty)
            insertMarkedText("い", state: .composing, controller: controller)
            XCTAssertEqual(client.document, "前あい後")
        }
    }

    func testPreviewUsesTheUTF16EndOfMarkedTextBeforeTheSuffix() throws {
        try withController { controller, client in
            insertMarkedText("😀", state: .previewing, controller: controller)
            XCTAssertEqual(client.document, "前😀後")
            XCTAssertEqual(client.markedRange(), NSRange(location: 1, length: 2))
            XCTAssertEqual(client.selectedRange(), NSRange(location: 3, length: 0))
        }
    }

    func testAnExplicitCompositionCaretRemainsInsideMarkedText() throws {
        try withController { controller, client in
            controller.segmentsManager.insertAtCursorPosition("あいう", inputStyle: .direct)
            controller.segmentsManager.moveCompositionCursor(.start)
            controller.segmentsManager.moveCompositionCursor(.forward)
            controller.inputState = .composing
            controller.refreshMarkedText()
            XCTAssertEqual(client.document, "前あいう後")
            XCTAssertEqual(client.markedRange(), NSRange(location: 1, length: 3))
            XCTAssertEqual(client.selectedRange(), NSRange(location: 2, length: 0))
        }
    }

    func testClearingAPreviewKeepsTheNextInputBeforeTheSuffix() throws {
        try withController { controller, client in
            insertMarkedText("あい", state: .previewing, controller: controller)
            controller.segmentsManager.stopComposition()
            controller.inputState = .none
            controller.refreshMarkedText()
            XCTAssertEqual(client.document, "前後")
            XCTAssertEqual(client.selectedRange(), NSRange(location: 1, length: 0))
            insertMarkedText("う", state: .composing, controller: controller)
            XCTAssertEqual(client.document, "前う後")
        }
    }
}
