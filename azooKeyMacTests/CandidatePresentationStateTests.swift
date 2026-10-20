import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class CandidatePresentationStateTests: XCTestCase {
    private let entries = [CandidateTree.Entry(text: "日本語", tokens: [.init(text: "日本語")], candidateIndex: 7)]

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func confirm(in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(in: view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "candidate-confirm"
        })
    }

    func testComposingCandidateIsAProposalAndItsButtonDoesNotAdvertiseEnter() throws {
        let view = CandidateTreeView()
        var submissions: [Int] = []
        view.onCandidateSubmitted = { submissions.append($0) }
        view.update(entries: entries, selectionIndex: 7)
        let heading = descendants(in: view).compactMap { $0 as? NSTextField }
        XCTAssertTrue(heading.contains { $0.stringValue == Localization.text("candidate.proposal") })
        XCTAssertEqual(view.accessibilityLabel(), Localization.text("candidate.proposal"))
        let button = try confirm(in: view)
        XCTAssertEqual(button.title, Localization.text("candidate.submitCandidate"))
        XCTAssertFalse(button.title.contains("↵"))
        XCTAssertEqual(button.accessibilityLabel(), Localization.text("candidate.submitCandidate"))
        button.performClick(nil)
        button.performClick(nil)
        XCTAssertEqual(submissions, [7], "The explicit button still submits the actual candidate once")
    }

    func testOnlyTheInputStatesEnterContractChangesTheDisplayedCommitHint() throws {
        let view = CandidateTreeView()
        var selections: [Int] = []
        var submissions: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.onCandidateSubmitted = { submissions.append($0) }
        view.update(entries: entries, selectionIndex: 7)
        try XCTUnwrap(descendants(in: view).compactMap { $0 as? CandidateRowButton }.first).performClick(nil)
        XCTAssertEqual(selections, [7])
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertEqual(try confirm(in: view).title, Localization.text("candidate.submitCandidate"))

        view.update(entries: entries, selectionIndex: 7, enterConfirmsCandidate: true)
        XCTAssertTrue(descendants(in: view).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == Localization.text("candidate.composition")
        })
        XCTAssertEqual(view.accessibilityLabel(), Localization.text("candidate.composition"))
        XCTAssertEqual(try confirm(in: view).title, Localization.text("candidate.submit") + "  ↵")
        XCTAssertEqual(selections, [7], "A presentation update never selects or submits a candidate")
        XCTAssertTrue(submissions.isEmpty)
    }

    func testChangingInputModeRetiresOldConfirmAndRowActionsEvenWhenTheCandidateIsIdentical() throws {
        let view = CandidateTreeView()
        var selections: [Int] = []
        var submissions: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.onCandidateSubmitted = { submissions.append($0) }
        view.update(entries: entries, selectionIndex: 7)
        let proposalConfirm = try confirm(in: view)
        let proposalRow = try XCTUnwrap(descendants(in: view).compactMap { $0 as? CandidateRowButton }.first)
        try XCTUnwrap(descendants(in: view).compactMap { $0 as? NSButton }.first {
            $0.title == Localization.text("candidate.openTree")
        }).performClick(nil)
        let proposalNode = try XCTUnwrap(descendants(in: view).compactMap { $0 as? TreeButton }.first)
        view.update(entries: entries, selectionIndex: 7, enterConfirmsCandidate: true)
        let selectedConfirm = try confirm(in: view)
        proposalConfirm.performClick(nil)
        proposalRow.performClick(nil)
        proposalNode.performClick(nil)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertTrue(submissions.isEmpty)

        view.update(entries: entries, selectionIndex: 7, enterConfirmsCandidate: false)
        selectedConfirm.performClick(nil)
        XCTAssertTrue(submissions.isEmpty)
        try confirm(in: view).performClick(nil)
        XCTAssertEqual(submissions, [7])
        XCTAssertFalse(descendants(in: view).compactMap { $0 as? NSButton }.contains { $0.acceptsFirstResponder })
    }

    func testCompactCandidateRowsKeepBothTextSizesAndAtLeastA44PointPointerTarget() throws {
        let page = CandidatePage(entries: entries, selectionIndex: 7)
        for size: CGFloat in [18, 24] {
            let item = try XCTUnwrap(page.items.first)
            let button = CandidateRowButton(item: item, number: "1", fontSize: size)
            let height = button.preferredHeight(width: 464)
            XCTAssertEqual(button.font?.pointSize, size)
            XCTAssertGreaterThanOrEqual(height, 44)
            XCTAssertLessThan(height, 52, "Short rows reduce padding while keeping the text and pointer target")
        }
    }

    func testNarrowFooterStacksActionsWithoutClippingTheConfirmTarget() throws {
        for width: CGFloat in [320, 480] {
            let view = CandidateActionsView(frame: .zero)
            view.update(candidateIndex: 7, generation: 1, treeExpanded: false, detailsExpanded: false,
                        enterConfirmsCandidate: false)
            view.setFrameSize(NSSize(width: width, height: view.preferredHeight(width: width)))
            view.layoutSubtreeIfNeeded()
            let buttons = descendants(in: view).compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, 3)
            for button in buttons {
                XCTAssertTrue(view.bounds.contains(button.frame))
                XCTAssertGreaterThanOrEqual(button.frame.height, 38)
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertFalse(button.acceptsFirstResponder)
            }
            let confirmFrame = try confirm(in: view).frame
            XCTAssertFalse(buttons.filter { $0.accessibilityIdentifier() != "candidate-confirm" }.contains {
                $0.frame.intersects(confirmFrame)
            })
        }
    }

    func testDisclosureActionsFromAnOldCandidateGenerationOrInputModeCannotToggleTheCurrentView() throws {
        let view = CandidateActionsView(frame: .zero)
        var treeToggles = 0
        var detailToggles = 0
        view.onTreeToggle = { treeToggles += 1 }
        view.onDetailsToggle = { detailToggles += 1 }
        view.update(candidateIndex: 7, generation: 1, treeExpanded: false, detailsExpanded: false,
                    enterConfirmsCandidate: false)
        let oldButtons = descendants(in: view).compactMap { $0 as? NSButton }.filter {
            $0.accessibilityIdentifier() != "candidate-confirm"
        }
        view.update(candidateIndex: 7, generation: 2, treeExpanded: false, detailsExpanded: false,
                    enterConfirmsCandidate: false)
        oldButtons.forEach { $0.performClick(nil) }
        XCTAssertEqual(treeToggles, 0)
        XCTAssertEqual(detailToggles, 0)

        let composingButtons = descendants(in: view).compactMap { $0 as? NSButton }.filter {
            $0.accessibilityIdentifier() != "candidate-confirm"
        }
        view.update(candidateIndex: 7, generation: 2, treeExpanded: false, detailsExpanded: false,
                    enterConfirmsCandidate: true)
        composingButtons.forEach { $0.performClick(nil) }
        XCTAssertEqual(treeToggles, 0)
        XCTAssertEqual(detailToggles, 0)
        descendants(in: view).compactMap { $0 as? NSButton }.filter {
            $0.accessibilityIdentifier() != "candidate-confirm"
        }.forEach { $0.performClick(nil) }
        XCTAssertEqual(treeToggles, 1)
        XCTAssertEqual(detailToggles, 1)
    }
}
