import Cocoa
import Core
import SwiftUI
import XCTest

@testable import azooKeyMac

@MainActor
final class PromptInputWindowTests: XCTestCase {
    private var window: PromptInputWindow!
    private static let configuration = AIRequestConfiguration(
        backend: .openAI, modelName: "test", apiKey: "", apiEndpoint: "https://example.invalid"
    )
    private static let field = AITextField(
        identity: ["test-client"], surrounding: .init(text: "日本語", cursorUTF16: 3, anchorUTF16: 0),
        hasSurroundingUpdate: true, isSensitive: false
    )
    private static let witness = AISelectionWitness(
        object: ["test-client"], window: ["test"], start: 0, end: 3, before: "", selected: "日本語", after: ""
    )

    private static func transformation() throws -> AISelectedTextTransformation {
        var transformation = try XCTUnwrap(AISelectedTextTransformation(
            id: 0, field: field, configuration: configuration.desktopConfiguration()
        ))
        let targetAvailable = transformation.attachWitness(witness, current: field)
        XCTAssertTrue(targetAvailable)
        return transformation
    }

    /// A transformation whose preview `text` the user chose to apply.
    private static func confirmed(_ text: String) throws -> AISelectedTextTransformation {
        var transformation = try Self.transformation()
        let started = try transformation.beginPreview(prompt: "翻訳", includeContext: false, field: field)
        let accepted = transformation.completePreview(revision: started.revision, text: text, inputContextChanged: false)
        let confirmed = transformation.confirm()
        XCTAssertTrue(accepted && confirmed)
        return transformation
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = PromptInputWindow()
    }

    override func tearDown() {
        window.close()
        window = nil
        super.tearDown()
    }

    private func show(
        onApply: @escaping (String) -> Void, completion: @escaping (String?) -> Void
    ) throws -> PromptInputView {
        let request = PromptInputRequest(
            initialPrompt: "翻訳", configuration: Self.configuration,
            transformation: try Self.transformation(), openedField: Self.field
        )
        window.showPromptInput(
            at: .zero, request: request,
            onPreview: { _, _ in XCTFail("this test must not start an AI request") },
            onApply: { onApply($0.applicableText ?? "") }, completion: completion
        )
        return try XCTUnwrap(window.contentView as? NSHostingView<PromptInputView>).rootView
    }

    func testApplyClosesTheWindowAndFinishesExactlyOnceBeforeRestoringFocus() throws {
        var prompts: [String?] = []
        var applied: [String] = []
        let view = try show(
            onApply: { [unowned self] text in
                XCTAssertFalse(window.isVisible)
                XCTAssertEqual(prompts, ["翻訳"])
                applied.append(text)
            },
            completion: { [unowned self] prompt in
                prompts.append(prompt)
                window.close()
            }
        )
        view.onApply(try Self.confirmed("English"), "翻訳")
        view.onApply(try Self.confirmed("duplicate"), "翻訳")
        XCTAssertEqual(prompts, ["翻訳"])
        XCTAssertEqual(applied, ["English"])
    }

    func testCancelCompletesOnceWithoutApplyingAResult() throws {
        var canceled = 0
        let view = try show(
            onApply: { _ in XCTFail("canceled preview must not apply") },
            completion: { prompt in
                XCTAssertNil(prompt)
                canceled += 1
            }
        )
        view.onCancel()
        window.close()
        XCTAssertEqual(canceled, 1)
    }

    func testAnOldPreviewCannotApplyToANewerWindowRequest() throws {
        let oldView = try show(onApply: { _ in XCTFail("old preview must not apply") }, completion: { _ in })
        var currentApplied: [String] = []
        var currentCompleted = 0
        let currentView = try show(
            onApply: { currentApplied.append($0) },
            completion: { _ in currentCompleted += 1 }
        )
        let oldArguments = AIRequestArguments(
            target: "日本語", leftContext: "", rightContext: "", includeContext: false,
            aiModel: "test", aiEndpoint: "https://example.invalid", prompt: "old prompt"
        )
        oldView.onPreview(oldArguments) { response in
            switch response {
            case .failure(.targetChanged): break
            default: XCTFail("old preview request must be rejected")
            }
        }
        oldView.onCancel()
        oldView.onApply(try Self.confirmed("old result"), "old prompt")
        XCTAssertTrue(currentApplied.isEmpty)
        XCTAssertEqual(currentCompleted, 0)
        XCTAssertTrue(window.isVisible)
        currentView.onApply(try Self.confirmed("current result"), "current prompt")
        XCTAssertEqual(currentApplied, ["current result"])
        XCTAssertEqual(currentCompleted, 1)
    }
}
