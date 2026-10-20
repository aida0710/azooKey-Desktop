import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@testable import azooKeyMac

@MainActor
private final class DeferredAIClient {
    private var requests: [CheckedContinuation<[String], Error>] = []
    private(set) var capturedRequests: [AISuggestionRequest] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func send(_ request: AISuggestionRequest) async throws -> [String] {
        capturedRequests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            for waiter in waiters where requests.count >= waiter.count { waiter.continuation.resume() }
            waiters.removeAll { requests.count >= $0.count }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count {
            return
        }
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
    private var controller: InputMethodTestController!
    private var client: FakeTextInput!
    private var sender: DeferredAIClient!
    private var directory: URL!
    private var restoreSettings: (() -> Void)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        let oldBackend = Config.AIBackendPreference().value
        let oldContext = Config.IncludeContextInAITransform().value
        let oldEndpoint = Config.OpenAiApiEndpoint().value
        let oldLive = Config.LiveConversion().value
        let oldTree = Config.TreeCandidates().value
        restoreSettings = {
            Config.AIBackendPreference().value = oldBackend
            Config.IncludeContextInAITransform().value = oldContext
            Config.OpenAiApiEndpoint().value = oldEndpoint
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
        let serverFixture = try InputMethodTestServer.shared
        controller = try XCTUnwrap(InputMethodTestController(
            server: serverFixture.server, client: client, segmentsManager: manager
        ))
        XCTAssertTrue(controller.client() === client)
        let deferredSender = sender!
        controller.aiSuggestionSession.sendRequest = { request in try await deferredSender.send(request) }
    }

    override func tearDown() {
        controller?.cancelReplaceSuggestion()
        controller = nil
        restoreSettings?()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
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

    private func beginRequest() throws -> Task<Void, Never> {
        controller.requestReplaceSuggestion()
        return try XCTUnwrap(controller.confirmReplaceSuggestion())
    }

    func testEnterDuringFirstRequestCommitsOriginalInputOnce() async throws {
        type("nihongo")
        let task = try beginRequest()
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

    func testMenuRequestKeepsOriginalInputUntilCandidatesArrive() async throws {
        type("nihongo")
        controller.performTransformSelectedText(NSMenuItem())
        _ = try XCTUnwrap(controller.confirmReplaceSuggestion())
        await sender.waitForRequests(1)
        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertEqual(client.marked, "にほんご")
        sender.finish(0, with: .success(["日本語"]))
        await controller.aiSuggestionSession.waitForPendingRequest()
        XCTAssertEqual(controller.inputState, .replaceSuggestion)
        send(.enter)
        XCTAssertEqual(client.inserted, ["日本語"])
    }

    func testEnterDuringMenuRequestCommitsOriginalInputOnce() async throws {
        type("nihongo")
        controller.performTransformSelectedText(NSMenuItem())
        _ = try XCTUnwrap(controller.confirmReplaceSuggestion())
        await sender.waitForRequests(1)
        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)
        sender.finish(0, with: .success(["日本語"]))
    }

    func testMenuPredictionKeepsItsInsertedReadingUntilCandidatesArrive() async throws {
        controller.performTransformSelectedText(NSMenuItem())
        _ = try XCTUnwrap(controller.confirmReplaceSuggestion())
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
        let first = try beginRequest()
        await sender.waitForRequests(1)
        sender.finish(0, with: .success(["旧候補 A"]))
        await first.value
        XCTAssertEqual(controller.inputState, .replaceSuggestion)

        send(.escape)
        send(.escape)
        type("nihongo")
        let second = try beginRequest()
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
        let first = try beginRequest()
        await sender.waitForRequests(1)
        controller.cancelReplaceSuggestion()
        let second = try beginRequest()
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
        let task = try beginRequest()
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
        let task = try beginRequest()
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
        let task = try beginRequest()
        await sender.waitForRequests(1)
        client.selection = NSRange(location: 1, length: 0)
        sender.finish(0, with: .success(["別の位置への候補"]))
        await task.value

        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertTrue(controller.replaceSuggestionsViewController.candidates.isEmpty)
        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
    }

    func testChangingClientsWithTheSameSelectionDiscardsAPendingResult() async throws {
        type("nihongo")
        let task = try beginRequest()
        await sender.waitForRequests(1)
        let otherClient = FakeTextInput()
        XCTAssertEqual(otherClient.selectedRange(), client.selectedRange())
        controller.activeClient = otherClient
        XCTAssertTrue(controller.client() === otherClient)
        sender.finish(0, with: .success(["別の入力欄への候補"]))
        await task.value

        XCTAssertTrue(controller.replaceSuggestionsViewController.candidates.isEmpty)
        XCTAssertTrue(client.inserted.isEmpty)
        XCTAssertTrue(otherClient.inserted.isEmpty)
        XCTAssertEqual(client.marked, "にほんご")
        XCTAssertEqual(otherClient.marked, "")
        controller.activeClient = client
        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertTrue(otherClient.inserted.isEmpty)
    }

    func testMissingClientCannotSendAPreparedRequestOrDiscardMarkedText() {
        type("nihongo")
        controller.requestReplaceSuggestion()
        XCTAssertNotNil(controller.aiSuggestionConfirmation)
        controller.activeClient = nil
        XCTAssertNil(controller.client())
        XCTAssertNil(controller.confirmReplaceSuggestion())
        XCTAssertNil(controller.aiSuggestionConfirmation)
        XCTAssertTrue(sender.capturedRequests.isEmpty)
        XCTAssertEqual(client.marked, "にほんご")
        XCTAssertTrue(client.inserted.isEmpty)

        controller.activeClient = client
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

    func testPredictionFromEmptyInputKeepsItsInsertedReadingWhileWaiting() async throws {
        XCTAssertTrue(send(.suggest))
        _ = try XCTUnwrap(controller.confirmReplaceSuggestion())
        await sender.waitForRequests(1)
        XCTAssertEqual(controller.inputState, .composing)
        XCTAssertEqual(controller.segmentsManager.convertTarget, "つづき")
        XCTAssertEqual(client.marked, "つづき")
        send(.enter)
        XCTAssertEqual(client.inserted, ["つづき"])
        XCTAssertTrue(controller.segmentsManager.isEmpty)
        sender.finish(0, with: .success([]))
    }

    func testReviewingTheSendScopeDoesNotSendAndEnterStillCommitsOriginalInput() {
        type("nihongo")
        XCTAssertNil(controller.requestReplaceSuggestion())
        XCTAssertNotNil(controller.aiSuggestionConfirmation)
        XCTAssertNil(controller.requestReplaceSuggestion())
        XCTAssertTrue(sender.capturedRequests.isEmpty)
        send(.enter)
        XCTAssertEqual(client.inserted, ["にほんご"])
        XCTAssertNil(controller.aiSuggestionConfirmation)
        XCTAssertTrue(sender.capturedRequests.isEmpty)
    }

    func testKeyboardCanToggleSurroundingTextAndCancelWithoutLosingInput() throws {
        type("nihongo")
        controller.requestReplaceSuggestion()
        let toggle = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "S", charactersIgnoringModifiers: "s",
            isARepeat: false, keyCode: 1
        ))
        XCTAssertEqual(controller.handleAISuggestionConfirmationKey(toggle), true)
        XCTAssertEqual(controller.aiSuggestionConfirmation?.includeContext, true)
        XCTAssertTrue(Config.IncludeContextInAITransform().value)
        let cancel = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ))
        XCTAssertEqual(controller.handleAISuggestionConfirmationKey(cancel), true)
        XCTAssertNil(controller.aiSuggestionConfirmation)
        XCTAssertEqual(controller.segmentsManager.convertTarget, "にほんご")
        XCTAssertTrue(sender.capturedRequests.isEmpty)
    }

    func testKeyboardSendUsesTheDestinationShownBeforeSettingsChanged() async throws {
        let endpoint = "https://user:credential@before.example.invalid/path?token=private"
        Config.OpenAiApiEndpoint().value = endpoint
        type("nihongo")
        controller.requestReplaceSuggestion()
        XCTAssertEqual(controller.aiSuggestionConfirmation?.configuration.destinationLabel, "before.example.invalid")
        Config.OpenAiApiEndpoint().value = "https://after.example.invalid"
        let send = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s",
            isARepeat: false, keyCode: 1
        ))
        XCTAssertEqual(controller.handleAISuggestionConfirmationKey(send), true)
        await sender.waitForRequests(1)
        XCTAssertEqual(sender.capturedRequests.first?.apiEndpoint, endpoint)
        sender.finish(0, with: .success([]))
        await controller.aiSuggestionSession.waitForPendingRequest()
        XCTAssertEqual(controller.inputState, .composing)
    }

    func testSuggestionAndStatusPanelsCannotTakeKeyboardFocus() {
        XCTAssertFalse(controller.replaceSuggestionWindow.canBecomeKey)
        XCTAssertFalse(controller.replaceSuggestionWindow.canBecomeMain)
        XCTAssertFalse(controller.aiSuggestionStatusPanel.canBecomeKey)
        XCTAssertFalse(controller.aiSuggestionStatusPanel.canBecomeMain)
        XCTAssertFalse(controller.aiSuggestionConfirmationPanel.canBecomeKey)
        XCTAssertFalse(controller.aiSuggestionConfirmationPanel.canBecomeMain)
    }
}
