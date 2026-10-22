import Cocoa
import Core
import XCTest

@testable import azooKeyMac

@MainActor
final class SelectedTextTransformTests: XCTestCase {
    // Allow the queued main-actor application to run; no external AI or IMK server is used.
    private let completionTimeout: TimeInterval = 2
    private var client: DocumentTextInput!
    private var session: MacSelectedTextTransformSession!
    private var target: SelectedTextReplacement!
    private var transformation: AISelectedTextTransformation!
    private var applicationIsActive = true
    private var activationSucceeds = true
    private var restorationRequests = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        client = DocumentTextInput()
        session = MacSelectedTextTransformSession()
        session.activate(client: client)
        let source = MacSelectedTextClient(client: client, focus: session, applicationIsActive: { true })
        target = try SelectedTextReplacement(client: source)
        transformation = try Self.confirmedTransformation(of: source, result: "翻訳")
    }

    /// Core's transformation of the source selection, with `result` chosen to apply.
    private static func confirmedTransformation(of source: MacSelectedTextClient, result: String) throws -> AISelectedTextTransformation {
        let configuration = AIRequestConfiguration(
            backend: .openAI, modelName: "test", apiKey: "", apiEndpoint: "https://example.invalid"
        )
        var transformation = try XCTUnwrap(AISelectedTextTransformation(
            id: 0, field: source.aiTextField(), configuration: configuration.desktopConfiguration()
        ))
        let targetAvailable = transformation.attachWitness(source.aiSelectionWitness(), current: source.aiTextField())
        let started = try transformation.beginPreview(prompt: "翻訳して", includeContext: false, field: source.aiTextField())
        let accepted = transformation.completePreview(revision: started.revision, text: result, inputContextChanged: false)
        let confirmed = transformation.confirm()
        XCTAssertTrue(targetAvailable && accepted && confirmed)
        return transformation
    }

    override func tearDown() {
        if let target { session?.cancel(target: target) }
        session = nil
        target = nil
        transformation = nil
        client = nil
        super.tearDown()
    }

    private func beginApplication(expecting applied: Bool) -> XCTestExpectation {
        let finished = expectation(description: "checked selection replacement completes")
        session.apply(
            target: target, transformation: transformation,
            application: .init(
                restoreFocus: { [weak self] in
                    self?.restorationRequests += 1
                    return self?.activationSucceeds == true
                },
                isActive: { [weak self] in self?.applicationIsActive == true }
            ),
            completion: { wasApplied in
                XCTAssertEqual(wasApplied, applied)
                finished.fulfill()
            }
        )
        return finished
    }

    func testRestoredOriginalClientIsReplacedOnceAfterActivation() async {
        session.deactivate(client: client)
        applicationIsActive = false
        let finished = beginApplication(expecting: true)
        XCTAssertEqual(restorationRequests, 1)
        XCTAssertTrue(client.replacements.isEmpty)
        applicationIsActive = true
        session.activate(client: client)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertEqual(client.document, "前翻訳後")
        XCTAssertEqual(client.replacements, ["翻訳"])
        session.activate(client: client)
        XCTAssertEqual(client.replacements, ["翻訳"])
    }

    func testAnotherClientWithTheSameTextAndSelectionIsNotReplaced() async {
        session.deactivate(client: client)
        let finished = beginApplication(expecting: false)
        let otherClient = DocumentTextInput()
        session.activate(client: otherClient)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertEqual(otherClient.document, "前日本語後")
        XCTAssertTrue(client.replacements.isEmpty)
        XCTAssertTrue(otherClient.replacements.isEmpty)
    }

    func testTextChangedWhileThePreviewWasOpenIsPreserved() async {
        client.document = "前別文章後"
        let finished = beginApplication(expecting: false)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertEqual(client.document, "前別文章後")
        XCTAssertTrue(client.replacements.isEmpty)
    }

    func testChangedSelectionIsNotReplaced() async {
        client.selection = NSRange(location: 0, length: 3)
        let finished = beginApplication(expecting: false)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertTrue(client.replacements.isEmpty)
    }

    func testDifferentReportedRangeIsNotReplaced() async {
        client.reportedActualRange = NSRange(location: 0, length: 3)
        let finished = beginApplication(expecting: false)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertTrue(client.replacements.isEmpty)
    }

    func testFocusLostAfterActivationBeforeApplicationDoesNotWrite() async {
        let finished = beginApplication(expecting: false)
        session.deactivate(client: client)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertTrue(client.replacements.isEmpty)
    }

    func testFailedApplicationActivationPreservesTheSelection() async {
        activationSucceeds = false
        let finished = beginApplication(expecting: false)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertEqual(restorationRequests, 1)
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertTrue(client.replacements.isEmpty)
    }

    func testInactiveApplicationAfterClientActivationDoesNotWrite() async {
        session.deactivate(client: client)
        applicationIsActive = false
        let finished = beginApplication(expecting: false)
        session.activate(client: client)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertTrue(client.replacements.isEmpty)
    }

    func testCanceledTargetCannotBeAppliedAfterFocusReturns() async {
        session.cancel(target: target)
        let finished = beginApplication(expecting: false)
        await fulfillment(of: [finished], timeout: completionTimeout)
        XCTAssertEqual(client.document, "前日本語後")
        XCTAssertTrue(client.replacements.isEmpty)
    }
}
