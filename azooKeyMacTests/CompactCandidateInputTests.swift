import AppKit
@testable import azooKeyMac
import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@MainActor
final class CompactCandidateInputTests: XCTestCase {
    private func withController(treeEnabled: Bool, operation: (InputMethodTestController, DocumentTextInput) throws -> Void) throws {
        _ = NSApplication.shared
        let oldLive = Config.LiveConversion().value
        let oldTree = Config.TreeCandidates().value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Live conversion is the default: the first Space opens the candidate list.
        // Without it the first Space only previews the first candidate.
        Config.LiveConversion().value = true
        Config.TreeCandidates().value = treeEnabled
        defer {
            Config.LiveConversion().value = oldLive
            Config.TreeCandidates().value = oldTree
            try? FileManager.default.removeItem(at: directory)
        }
        let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
                                      containerURL: nil, context: .init(useZenzai: false))
        manager.learningEnabled = false
        let client = DocumentTextInput()
        client.document = ""
        client.selection = NSRange(location: 0, length: 0)
        let fixture = try InputMethodTestServer.shared
        let controller = try XCTUnwrap(InputMethodTestController(server: fixture.server, client: client, segmentsManager: manager))
        defer { controller.commitComposition(client) }
        try operation(controller, client)
    }

    private func press(_ code: UInt16, text: String, modifiers: NSEvent.ModifierFlags = [],
                       controller: InputMethodTestController, client: DocumentTextInput) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        XCTAssertTrue(controller.handle(event, client: client))
    }

    private func startConversion(_ controller: InputMethodTestController, client: DocumentTextInput) throws {
        XCTAssertTrue(controller.handleClientAction(.appendToMarkedText("tesuto"), clientActionCallback: .transition(.composing), client: client))
        try press(49, text: " ", controller: controller, client: client)
        XCTAssertEqual(controller.inputState, .selecting)
    }

    private func selection(_ controller: InputMethodTestController) throws -> Int {
        guard case .selecting(_, let index) = controller.segmentsManager.getCurrentCandidateWindow(inputState: controller.inputState) else {
            XCTFail("The candidate list must still be selecting")
            return -1
        }
        return try XCTUnwrap(index)
    }

    func testPageKeysAndNumberConfirmationWorkWithTreeEnabledAndDisabled() throws {
        for treeEnabled in [false, true] {
            try withController(treeEnabled: treeEnabled) { controller, client in
                try startConversion(controller, client: client)
                XCTAssertEqual(try selection(controller), 0)
                try press(121, text: "\u{f72d}", controller: controller, client: client)
                XCTAssertEqual(try selection(controller), 9)
                try press(116, text: "\u{f72c}", controller: controller, client: client)
                XCTAssertEqual(try selection(controller), 0)
                for _ in 0..<9 { try press(125, text: "\u{f701}", controller: controller, client: client) }
                XCTAssertEqual(try selection(controller), 9)
                let chosen = try XCTUnwrap(controller.segmentsManager.selectedCandidate).text
                try press(18, text: "1", controller: controller, client: client)
                XCTAssertTrue(client.document.hasPrefix(chosen))
                XCTAssertNotEqual(controller.inputState, .selecting)
            }
        }
    }

    func testArrowsEnterEscapeAndSegmentResizingKeepTheInputContract() throws {
        try withController(treeEnabled: true) { controller, client in
            try startConversion(controller, client: client)
            try press(125, text: "\u{f701}", controller: controller, client: client)
            XCTAssertEqual(try selection(controller), 1)
            try press(126, text: "\u{f700}", controller: controller, client: client)
            XCTAssertEqual(try selection(controller), 0)
            let chosen = try XCTUnwrap(controller.segmentsManager.selectedCandidate).text
            try press(36, text: "\r", controller: controller, client: client)
            XCTAssertEqual(client.document, chosen)
            XCTAssertEqual(controller.inputState, .none)
            client.document = ""
            client.selection = NSRange(location: 0, length: 0)
            try startConversion(controller, client: client)
            let fullReading = controller.segmentsManager.convertTarget
            XCTAssertTrue(controller.segmentsManager.consumesWholeComposition(try XCTUnwrap(controller.segmentsManager.selectedCandidate)))
            try press(123, text: "\u{f702}", modifiers: .shift, controller: controller, client: client)
            XCTAssertEqual(controller.inputState, .selecting)
            XCTAssertFalse(controller.segmentsManager.isEmpty)
            XCTAssertEqual(controller.segmentsManager.convertTarget, fullReading)
            XCTAssertFalse(controller.segmentsManager.consumesWholeComposition(try XCTUnwrap(controller.segmentsManager.selectedCandidate)))
            try press(124, text: "\u{f703}", modifiers: .shift, controller: controller, client: client)
            XCTAssertEqual(controller.inputState, .selecting)
            XCTAssertTrue(controller.segmentsManager.consumesWholeComposition(try XCTUnwrap(controller.segmentsManager.selectedCandidate)))
            // With live conversion, Esc closes the list and keeps the whole reading.
            try press(53, text: "\u{1b}", controller: controller, client: client)
            XCTAssertEqual(controller.inputState, .composing)
            XCTAssertEqual(controller.segmentsManager.convertTarget, fullReading)
        }
    }
}
