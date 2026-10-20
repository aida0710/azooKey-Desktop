import Cocoa
import Core
import SwiftUI
import XCTest

@testable import azooKeyMac

@MainActor
final class PromptInputWindowTests: XCTestCase {
    private var window: PromptInputWindow!
    private let request = PromptInputRequest(
        initialPrompt: "翻訳",
        configuration: AIRequestConfiguration(
            backend: .openAI, modelName: "test", apiKey: "", apiEndpoint: "https://example.invalid"
        ),
        targetText: "日本語"
    )

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
        window.showPromptInput(
            at: .zero, request: request,
            onPreview: { _, _, _ in XCTFail("this test must not start an AI request") },
            onApply: onApply, completion: completion
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
        view.onApply("English", "翻訳")
        view.onApply("duplicate", "翻訳")
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
        oldView.onPreview("old prompt", false) { response in
            switch response {
            case .failure(.targetChanged): break
            default: XCTFail("old preview request must be rejected")
            }
        }
        oldView.onCancel()
        oldView.onApply("old result", "old prompt")
        XCTAssertTrue(currentApplied.isEmpty)
        XCTAssertEqual(currentCompleted, 0)
        XCTAssertTrue(window.isVisible)
        currentView.onApply("current result", "current prompt")
        XCTAssertEqual(currentApplied, ["current result"])
        XCTAssertEqual(currentCompleted, 1)
    }
}
