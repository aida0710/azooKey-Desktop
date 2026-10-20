import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@testable import azooKeyMac

@MainActor
private final class DeferredAIClient {
    private var requests: [CheckedContinuation<[String], Error>] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func send(_ request: AISuggestionRequest) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            for waiter in waiters where requests.count >= waiter.count { waiter.continuation.resume() }
            waiters.removeAll { requests.count >= $0.count }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish(_ index: Int, with response: Result<[String], Error>) {
        requests[index].resume(with: response)
    }
}

/// Records the InputMethodKit boundary. The test controller calls it on the main actor.
private final class FakeTextInput: NSObject, IMKTextInput {
    var inserted: [String] = []
    var marked = ""
    var selection = NSRange(location: 0, length: 0)

    func insertText(_ string: Any!, replacementRange: NSRange) {
        inserted.append((string as? NSAttributedString)?.string ?? string as? String ?? "")
        marked = ""
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    }

    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { NSRange(location: 0, length: marked.utf16.count) }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { NSAttributedString(string: "") }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect {
        NSRect(x: 100, y: 200, width: 1, height: 20)
    }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int {
        inMarkedRange?.pointee = false
        return 0
    }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle rect: NSRectPointer!) -> [AnyHashable: Any]! {
        rect?.pointee = NSRect(x: 100, y: 200, width: 1, height: 20)
        return [:]
    }
    func length() -> Int { marked.utf16.count }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        actualRange?.pointee = NSRange(location: 0, length: 0)
        return ""
    }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "azookey-tests-fake-client" }
    func windowLevel() -> CGWindowLevel { CGWindowLevel(NSWindow.Level.normal.rawValue) }
    func bundleIdentifier() -> String! { "azookey.tests.fake-client" }
}

@MainActor
final class AISuggestionInputTests: XCTestCase {
    private var controller: azooKeyMacInputController!
    private var client: FakeTextInput!
    private var sender: DeferredAIClient!
    private var directory: URL!
    private var restoreSettings: (() -> Void)!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        let oldBackend = Config.AIBackendPreference().value
        let oldContext = Config.IncludeContextInAITransform().value
        let oldLive = Config.LiveConversion().value
        let oldTree = Config.TreeCandidates().value
        restoreSettings = {
            Config.AIBackendPreference().value = oldBackend
            Config.IncludeContextInAITransform().value = oldContext
            Config.LiveConversion().value = oldLive
            Config.TreeCandidates().value = oldTree
        }
        Config.AIBackendPreference().value = .openAI
        Config.IncludeContextInAITransform().value = false
        Config.LiveConversion().value = false
        Config.TreeCandidates().value = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
            containerURL: nil, context: .init(useZenzai: false)
        )
        client = FakeTextInput()
        sender = DeferredAIClient()
        controller = azooKeyMacInputController(
            server: IMKServer(), delegate: nil, client: client, segmentsManager: manager
        )
        let deferredSender = sender!
        controller.aiSuggestionSession.sendRequest = { request in try await deferredSender.send(request) }
    }

    override func tearDown() {
        controller.cancelReplaceSuggestion()
        controller = nil
        restoreSettings()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func type(_ text: String) {
        XCTAssertTrue(controller.handleClientAction(
            .appendToMarkedText(text), clientActionCallback: .transition(.composing), client: client
        ))
    }

    @discardableResult
    private func send(_ userAction: UserAction) -> Bool {
        let (action, callback) = controller.inputState.event(
            eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0),
            userAction: userAction, inputLanguage: .japanese,
            liveConversionEnabled: false, enableDebugWindow: false, enableSuggestion: true
        )
        return controller.handleClientAction(action, clientActionCallback: callback, client: client)
    }

    func testEnterDuringFirstRequestCommitsOriginalInputOnce() async throws {
        type("nihongo")
        let task = try XCTUnwrap(controller.requestReplaceSuggestion())
        await sender.waitForRequests(1)

        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)
        XCTAssertEqual(controller.inputState, .none)
        XCTAssertEqual(client.marked, "")

        sender.finish(0, with: .success(["遅れて届いた候補"]))
        await task.value
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertTrue(controller.replaceSuggestionsViewController.candidates.isEmpty)
        XCTAssertEqual(client.marked, "")
    }

    func testMenuRequestKeepsOriginalInputUntilCandidatesArrive() async {
        type("nihongo")
        controller.performTransformSelectedText(NSMenuItem())
        await sender.waitForRequests(1)
        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertEqual(client.marked, "にほんご")
        sender.finish(0, with: .success(["日本語"]))
        await controller.aiSuggestionSession.waitForPendingRequest()
        XCTAssertEqual(controller.inputState, .replaceSuggestion)
        send(.enter)
        XCTAssertEqual(client.inserted, ["日本語"])
    }

    func testEnterDuringMenuRequestCommitsOriginalInputOnce() async {
        type("nihongo")
        controller.performTransformSelectedText(NSMenuItem())
        await sender.waitForRequests(1)
        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)
        sender.finish(0, with: .success(["日本語"]))
    }

    func testMenuPredictionKeepsItsInsertedReadingUntilCandidatesArrive() async {
        controller.performTransformSelectedText(NSMenuItem())
        await sender.waitForRequests(1)
        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertEqual(client.marked, "つづき")
        sender.finish(0, with: .success(["続きの文章"]))
        await controller.aiSuggestionSession.waitForPendingRequest()
        send(.enter)
        XCTAssertEqual(client.inserted, ["続きの文章"])
    }

    func testEnterWhileNewRequestIsPendingCannotCommitPreviouslyDisplayedCandidate() async throws {
        type("mae")
        let first = try XCTUnwrap(controller.requestReplaceSuggestion())
        await sender.waitForRequests(1)
        sender.finish(0, with: .success(["旧候補 A"]))
        await first.value
        XCTAssertEqual(controller.inputState, .replaceSuggestion)

        send(.escape)
        send(.escape)
        type("nihongo")
        let second = try XCTUnwrap(controller.requestReplaceSuggestion())
        await sender.waitForRequests(2)
        XCTAssertTrue(controller.replaceSuggestionsViewController.candidates.isEmpty)
        send(.enter)
        sender.finish(1, with: .success(["新しい候補"]))
        await second.value

        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)
        XCTAssertEqual(client.marked, "")
    }

    func testSameReadingRequestsReturnedInReverseOrderKeepOnlyTheNewCandidate() async throws {
        type("nihongo")
        let first = try XCTUnwrap(controller.requestReplaceSuggestion())
        await sender.waitForRequests(1)
        controller.cancelReplaceSuggestion()
        let second = try XCTUnwrap(controller.requestReplaceSuggestion())
        await sender.waitForRequests(2)
        sender.finish(1, with: .success(["新しい候補 B"]))
        await second.value
        sender.finish(0, with: .success(["古い候補 A"]))
        await first.value

        XCTAssertEqual(controller.replaceSuggestionsViewController.getSelectedCandidate()?.text, "新しい候補 B")
        send(.enter)
        XCTAssertEqual(client.inserted, ["新しい候補 B"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)
    }

    func testEmptyResultsPreserveOriginalInputForEnter() async throws {
        type("nihongo")
        let task = try XCTUnwrap(controller.requestReplaceSuggestion())
        await sender.waitForRequests(1)
        sender.finish(0, with: .success([]))
        await task.value

        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertEqual(client.marked, "にほんご")
        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)
    }

    func testFailureKeepsNumbersBackspaceEscapeAndEnterUsable() async throws {
        type("nihongo")
        let task = try XCTUnwrap(controller.requestReplaceSuggestion())
        await sender.waitForRequests(1)
        sender.finish(0, with: .failure(URLError(.timedOut)))
        await task.value

        send(.number(.one))
        XCTAssertEqual(controller.segmentsManager.convertTarget, "にほんご1")
        send(.backspace)
        XCTAssertEqual(controller.segmentsManager.convertTarget, "にほんご")
        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)

        type("tugi")
        send(.escape)
        XCTAssertFalse(send(.enter))
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertEqual(client.marked, "")
    }

    func testMovingTheClientSelectionDiscardsAPendingResult() async throws {
        type("nihongo")
        let task = try XCTUnwrap(controller.requestReplaceSuggestion())
        await sender.waitForRequests(1)
        client.selection = NSRange(location: 1, length: 0)
        sender.finish(0, with: .success(["別の位置への候補"]))
        await task.value

        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertTrue(controller.replaceSuggestionsViewController.candidates.isEmpty)
        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
    }

    func testEmptyReplacementRequestLeavesEnterToTheApplication() {
        XCTAssertNil(controller.requestReplaceSuggestion())
        XCTAssertEqual(controller.inputState, .none)
        XCTAssertFalse(send(.enter))
        XCTAssertTrue(client.inserted.isEmpty)
        type("nihongo")
        XCTAssertEqual(controller.segmentsManager.convertTarget, "にほんご")
    }

    func testPredictionFromEmptyInputKeepsItsInsertedReadingWhileWaiting() async {
        XCTAssertTrue(send(.suggest))
        await sender.waitForRequests(1)
        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertEqual(controller.segmentsManager.convertTarget, "つづき")
        XCTAssertEqual(client.marked, "つづき")
        send(.enter)
        XCTAssertEqual(client.inserted, ["つづき"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)
        sender.finish(0, with: .success([]))
    }

    func testSuggestionAndStatusPanelsCannotTakeKeyboardFocus() {
        XCTAssertFalse(controller.replaceSuggestionWindow.canBecomeKey)
        XCTAssertFalse(controller.replaceSuggestionWindow.canBecomeMain)
        XCTAssertFalse(controller.aiSuggestionStatusPanel.canBecomeKey)
        XCTAssertFalse(controller.aiSuggestionStatusPanel.canBecomeMain)
    }
}
