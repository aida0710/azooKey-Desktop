import AppKit
@testable import azooKeyMac
import Core
import KanaKanjiConverterModule
import XCTest

@MainActor
final class CandidateConfirmationAdapterTests: XCTestCase {
    private final class DelegateSpy: CandidatesViewControllerDelegate {
        var selectedRows: [Int] = []
        var submittedCount = 0

        func candidateSubmitted() { submittedCount += 1 }
        func candidateSelectionChanged(_ row: Int) { selectedRows.append(row) }
    }

    private var oldTreeCandidates = false
    private var controller: CandidatesViewController!
    private var delegate: DelegateSpy!
    private let candidates = ["候補1", "候補2"].map {
        CandidatePresentation(candidate: Candidate(
            text: $0, value: 0, composingCount: .surfaceCount(0), lastMid: 0, data: []
        ))
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        oldTreeCandidates = Config.TreeCandidates().value
        Config.TreeCandidates().value = true
        controller = CandidatesViewController()
        delegate = DelegateSpy()
        controller.delegate = delegate
        _ = controller.view
    }

    override func tearDown() {
        controller = nil
        delegate = nil
        Config.TreeCandidates().value = oldTreeCandidates
        super.tearDown()
    }

    private func confirmButton() throws -> NSButton {
        let tree = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? CandidateTreeView }.first)
        let actions = try XCTUnwrap(tree.subviews.compactMap { $0 as? CandidateActionsView }.first)
        return try XCTUnwrap(actions.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "candidate-confirm"
        })
    }

    func testSelectionRefreshPreservesTheEnterHintAfterRenderingAndMovingToTheNextCandidate() throws {
        controller.updateCandidatePresentations(
            candidates, selectionIndex: 0, cursorLocation: .zero, enterConfirmsCandidate: true
        )
        XCTAssertEqual(try confirmButton().title, Localization.text("candidate.submit") + "  ↵")
        XCTAssertTrue(delegate.selectedRows.isEmpty)
        XCTAssertEqual(delegate.submittedCount, 0)

        controller.selectNextCandidate()

        XCTAssertEqual(controller.currentSelectedRow, 1)
        XCTAssertEqual(try confirmButton().title, Localization.text("candidate.submit") + "  ↵")
        XCTAssertEqual(delegate.selectedRows, [1])
        XCTAssertEqual(delegate.submittedCount, 0)
    }

    func testReturningToCompositionRemovesEnterAndRetiresTheOldConfirmButton() throws {
        controller.updateCandidatePresentations(
            candidates, selectionIndex: 0, cursorLocation: .zero, enterConfirmsCandidate: true
        )
        let selectedConfirm = try confirmButton()

        controller.updateCandidatePresentations(
            candidates, selectionIndex: 0, cursorLocation: .zero, enterConfirmsCandidate: false
        )

        XCTAssertEqual(try confirmButton().title, Localization.text("candidate.submitCandidate"))
        selectedConfirm.performClick(nil)
        XCTAssertTrue(delegate.selectedRows.isEmpty)
        XCTAssertEqual(delegate.submittedCount, 0)
    }

    func testShowingCandidatesAfterHideDefaultsToAProposal() throws {
        controller.updateCandidatePresentations(
            candidates, selectionIndex: 0, cursorLocation: .zero, enterConfirmsCandidate: true
        )
        controller.hide()

        controller.updateCandidatePresentations(candidates, selectionIndex: 0, cursorLocation: .zero)

        XCTAssertEqual(try confirmButton().title, Localization.text("candidate.submitCandidate"))
        XCTAssertTrue(delegate.selectedRows.isEmpty)
        XCTAssertEqual(delegate.submittedCount, 0)
    }
}
