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
        let actions = try XCTUnwrap(descendants(in: tree).compactMap { $0 as? CandidateActionsView }.first)
        return try XCTUnwrap(actions.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "candidate-confirm"
        })
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func candidatePresentations(count: Int) -> [CandidatePresentation] {
        (0..<count).map { index in
            CandidatePresentation(candidate: Candidate(
                text: "候補\(index)", value: 0, composingCount: .surfaceCount(0), lastMid: 0, data: []
            ))
        }
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

    func testLiveReferenceNumbersUseTheExistingPageWithoutChangingThePhysicalNumberFlag() throws {
        let candidates = candidatePresentations(count: 20)
        controller.showCandidateIndex = false
        controller.updateCandidatePresentations(candidates, selectionIndex: 9, cursorLocation: .zero)
        let words = descendants(in: controller.view).compactMap { $0 as? TreeButton }
        XCTAssertEqual(try XCTUnwrap(words.first { $0.title == "候補9" }).candidateNumber, "1")
        XCTAssertFalse(controller.showCandidateIndex)
        XCTAssertEqual(controller.currentSelectedRow, 9)
        XCTAssertTrue(delegate.selectedRows.isEmpty)
        XCTAssertEqual(delegate.submittedCount, 0)

        controller.selectNextCandidate()

        let nextWords = descendants(in: controller.view).compactMap { $0 as? TreeButton }
        XCTAssertEqual(try XCTUnwrap(nextWords.first { $0.title == "候補10" }).candidateNumber, "2")
        XCTAssertFalse(controller.showCandidateIndex)
        XCTAssertEqual(controller.currentSelectedRow, 10)
        XCTAssertEqual(delegate.selectedRows, [10])
        XCTAssertEqual(delegate.submittedCount, 0)
    }

    func testMenuNumberVisibilityStillFollowsTheExistingFlagAfterLiveReferenceNumbers() throws {
        let candidates = candidatePresentations(count: 12)
        for showsPhysicalNumbers in [false, true] {
            controller.showCandidateIndex = showsPhysicalNumbers
            controller.updateCandidatePresentations(candidates, selectionIndex: 9, cursorLocation: .zero)
            XCTAssertEqual(controller.showCandidateIndex, showsPhysicalNumbers)
            controller.updateCandidatePresentations(
                candidates, selectionIndex: 9, cursorLocation: .zero, enterConfirmsCandidate: true
            )
            let rows = descendants(in: controller.view).compactMap { $0 as? CandidateRowButton }
            let selected = try XCTUnwrap(rows.first { $0.candidateIndex == 9 })
            XCTAssertEqual(selected.title, showsPhysicalNumbers ? "1. 候補9" : "候補9")
            XCTAssertEqual(controller.showCandidateIndex, showsPhysicalNumbers)
            XCTAssertEqual(controller.currentSelectedRow, 9)
        }
        XCTAssertTrue(delegate.selectedRows.isEmpty)
        XCTAssertEqual(delegate.submittedCount, 0)
    }

    func testPressingALiveReferenceNumberSelectsItsActualCandidateWithoutSubmittingOrChangingTheNumberFlag() throws {
        controller.showCandidateIndex = false
        controller.updateCandidatePresentations(
            candidatePresentations(count: 12), selectionIndex: 9, cursorLocation: .zero
        )
        let selectedWord = try XCTUnwrap(descendants(in: controller.view).compactMap { $0 as? TreeButton }.first {
            $0.title == "候補9" && $0.candidateNumber == "1"
        })
        selectedWord.performClick(nil)
        XCTAssertEqual(delegate.selectedRows, [9])
        XCTAssertEqual(delegate.submittedCount, 0)
        XCTAssertFalse(controller.showCandidateIndex)
    }

    func testHidingLiveCandidatesDiscardsThePreviousReferencePage() throws {
        controller.showCandidateIndex = false
        controller.updateCandidatePresentations(
            candidatePresentations(count: 12), selectionIndex: 9, cursorLocation: .zero
        )
        let oldWord = try XCTUnwrap(descendants(in: controller.view).compactMap { $0 as? TreeButton }.first {
            $0.title == "候補9"
        })
        controller.hide()
        oldWord.performClick(nil)
        XCTAssertTrue(delegate.selectedRows.isEmpty)
        controller.updateCandidatePresentations(candidates, selectionIndex: 0, cursorLocation: .zero)
        let currentWords = descendants(in: controller.view).compactMap { $0 as? TreeButton }
        XCTAssertEqual(try XCTUnwrap(currentWords.first { $0.title == "候補1" }).candidateNumber, "1")
        XCTAssertFalse(currentWords.contains { $0.title == "候補9" })
        XCTAssertFalse(controller.showCandidateIndex)
        XCTAssertEqual(delegate.submittedCount, 0)
    }

    func testSharedPrefixReferenceNumberMatchesItsActualWordAction() throws {
        let view = CandidateTreeView()
        let entries: [CandidateTree.Entry] = [
            .init(text: "日本語", tokens: [.init(text: "日本"), .init(text: "語")], candidateIndex: 7),
            .init(text: "日本画", tokens: [.init(text: "日本"), .init(text: "画")], candidateIndex: 42)
        ]
        var selected: [Int] = []
        var submitted: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 7, numbers: [7: "1", 42: "2"])
        let prefix = try XCTUnwrap(descendants(in: view).compactMap { $0 as? TreeButton }.first { $0.title == "日本" })
        XCTAssertEqual(prefix.candidateNumber, "1", "A nonterminal prefix uses the same existing number map as its word action")
        prefix.performClick(nil)
        XCTAssertEqual(selected, [7])
        XCTAssertTrue(submitted.isEmpty)
        view.update(entries: entries, selectionIndex: 42, numbers: [7: "1"])
        XCTAssertNil(try XCTUnwrap(descendants(in: view).compactMap { $0 as? TreeButton }.first { $0.title == "日本" }).candidateNumber,
                     "A candidate outside the existing number map receives no invented reference number")
    }
}
