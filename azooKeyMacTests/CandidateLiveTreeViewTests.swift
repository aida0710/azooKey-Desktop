import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class CandidateLiveTreeViewTests: XCTestCase {
    private let entries: [CandidateTree.Entry] = [
        .init(text: "日本語", tokens: [.init(text: "日本"), .init(text: "語")], candidateIndex: 7),
        .init(text: "日本画", tokens: [.init(text: "日本"), .init(text: "画")], candidateIndex: 42)
    ]

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func button(in view: NSView, identifier: String) throws -> NSButton {
        try XCTUnwrap(descendants(in: view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == identifier
        })
    }

    private func treeArea(in view: CandidateTreeView) throws -> NSScrollView {
        try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier() == "candidate-segments" } as? NSScrollView)
    }

    func testLiveCompositionShowsTheSelectedPathAndRealBranchesWithoutTheLargeMenu() throws {
        let view = CandidateTreeView()
        view.update(entries: entries, selectionIndex: 7)
        XCTAssertFalse(try treeArea(in: view).isHidden)
        XCTAssertEqual(Set(descendants(in: view).compactMap { $0 as? TreeButton }.map(\.title)), ["日本", "語", "画"])
        XCTAssertTrue(descendants(in: view).compactMap { $0 as? TreeButton }.allSatisfy { $0.candidateNumber == nil })
        XCTAssertTrue(try XCTUnwrap(view.subviews.compactMap { $0 as? CandidateNavigationView }.first).isHidden)
        XCTAssertTrue(try XCTUnwrap(view.subviews.compactMap { $0 as? CandidateCompositionView }.first).isHidden)
        XCTAssertTrue(try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier() == "candidate-details" }).isHidden)
        let liveHeight = view.preferredSize.height

        view.update(entries: entries, selectionIndex: 7, numbers: [7: "1", 42: "2"], enterConfirmsCandidate: true)
        XCTAssertTrue(try treeArea(in: view).isHidden)
        XCTAssertFalse(try XCTUnwrap(view.subviews.compactMap { $0 as? CandidateNavigationView }.first).isHidden)
        XCTAssertGreaterThan(view.preferredSize.height, liveHeight)
        XCTAssertEqual(try button(in: view, identifier: "candidate-confirm").title, Localization.text("candidate.submit") + "  ↵")
    }

    func testOnlyExplicitDisclosureExpandsWordEditingAndSamePhaseRedrawKeepsItOpen() throws {
        let view = CandidateTreeView()
        let alternatives = (0..<6).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        view.update(entries: alternatives, selectionIndex: 0)
        let compactCount = descendants(in: view).compactMap { $0 as? TreeButton }.count
        XCTAssertEqual(compactCount, 3)
        try button(in: view, identifier: "candidate-tree-toggle").performClick(nil)
        XCTAssertGreaterThan(descendants(in: view).compactMap { $0 as? TreeButton }.count, compactCount)
        try button(in: view, identifier: "candidate-details-toggle").performClick(nil)
        view.update(entries: alternatives, selectionIndex: 0)
        XCTAssertEqual(try button(in: view, identifier: "candidate-tree-toggle").title, Localization.text("candidate.closeTree"))
        XCTAssertFalse(try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier() == "candidate-details" }).isHidden)

        view.update(entries: alternatives, selectionIndex: 0, enterConfirmsCandidate: true)
        XCTAssertTrue(try treeArea(in: view).isHidden)
        try button(in: view, identifier: "candidate-tree-toggle").performClick(nil)
        XCTAssertFalse(try treeArea(in: view).isHidden)
        view.update(entries: alternatives, selectionIndex: 0, enterConfirmsCandidate: true)
        XCTAssertFalse(try treeArea(in: view).isHidden)
    }

    func testSwitchingBackToLiveRetiresMenuActionsAndPreservesTheActualCandidateSelection() throws {
        let view = CandidateTreeView()
        var selections: [Int] = []
        var submissions: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.onCandidateSubmitted = { submissions.append($0) }
        view.update(entries: entries, selectionIndex: 42, enterConfirmsCandidate: true)
        try button(in: view, identifier: "candidate-tree-toggle").performClick(nil)
        let oldConfirm = try button(in: view, identifier: "candidate-confirm")
        let oldRow = try XCTUnwrap(descendants(in: view).compactMap { $0 as? CandidateRowButton }.first)
        let oldWord = try XCTUnwrap(descendants(in: view).compactMap { $0 as? TreeButton }.first)
        view.update(entries: entries, selectionIndex: 42)
        [oldConfirm, oldRow, oldWord].forEach { $0.performClick(nil) }
        XCTAssertTrue(selections.isEmpty)
        XCTAssertTrue(submissions.isEmpty)
        XCTAssertTrue(descendants(in: view).compactMap { $0 as? TreeButton }.contains {
            $0.title == "画" && $0.isAccessibilitySelected()
        })
        XCTAssertEqual(try button(in: view, identifier: "candidate-tree-toggle").title, Localization.text("candidate.openTree"))
    }

    func testSameLiveSnapshotPreservesTheManuallyScrolledTreeViewport() throws {
        let view = CandidateTreeView()
        let words = (0..<24).map { CandidateTree.Token(text: "文節\($0)") }
        let longEntry = CandidateTree.Entry(text: words.map(\.text).joined(), tokens: words, candidateIndex: 42)
        view.update(entries: [longEntry], selectionIndex: 42)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let scroll = try treeArea(in: view)
        let canvas = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(canvas.bounds.width, scroll.contentSize.width)
        let offset = min(120, canvas.bounds.width - scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let viewport = scroll.contentView.bounds
        view.update(entries: [longEntry], selectionIndex: 42)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds, viewport)
    }

    func testLowerLeftNumbersShareWordActionsAndNeverRenumberTheOriginalCandidates() throws {
        let preference = Config.CandidateTextSize()
        let previous = preference.value
        defer { preference.value = previous }
        for size in [Config.CandidateTextSize.Value.standard, .large] {
            preference.value = size
            let view = CandidateTreeView()
            var selections: [Int] = []
            var submissions: [Int] = []
            view.onSelectionChanged = { selections.append($0) }
            view.onCandidateSubmitted = { submissions.append($0) }
            view.update(entries: entries, selectionIndex: 42, numbers: [7: "8", 42: "9"], enterConfirmsCandidate: true)
            try button(in: view, identifier: "candidate-tree-toggle").performClick(nil)
            let words = descendants(in: view).compactMap { $0 as? TreeButton }
            let alternative = try XCTUnwrap(words.first { $0.candidateNumber == "8" })
            let badge = try XCTUnwrap(alternative.numberBadgeFrame)
            XCTAssertTrue(alternative.bounds.contains(badge))
            XCTAssertLessThan(badge.midX, alternative.bounds.midX)
            XCTAssertLessThan(badge.midY, alternative.bounds.midY)
            XCTAssertLessThan(badge.maxY, alternative.candidateTextFrame.minY)
            XCTAssertEqual(alternative.font?.pointSize, CGFloat(CandidateTextMetrics.baseFontSize(size)))
            XCTAssertGreaterThanOrEqual(alternative.frame.height, 44)
            XCTAssertLessThan(alternative.frame.height, 88)
            XCTAssertTrue(alternative.accessibilityHelp()?.contains(String(format: Localization.text("candidate.numberBadge"), "8")) == true)
            XCTAssertFalse(words.contains { $0.title == "8" || $0.title == "9" })
            alternative.performClick(nil)
            XCTAssertEqual(selections, [7])
            XCTAssertTrue(submissions.isEmpty)
            XCTAssertFalse(alternative.acceptsFirstResponder)
        }
    }

    func testASharedWordsBadgeMatchesItsSelectionWhileTheMenuKeepsThePartialCandidateNumber() throws {
        let view = CandidateTreeView()
        let partial: [CandidateTree.Entry] = [
            .init(text: "日本語", tokens: [.init(text: "日本語")], candidateIndex: 7,
                  scope: .init(consumedReading: "にほんご", remainingReading: "にゅうりょく")),
            .init(text: "日本語入力", tokens: [.init(text: "日本語"), .init(text: "入力")], candidateIndex: 42)
        ]
        var selections: [Int] = []
        var submissions: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.onCandidateSubmitted = { submissions.append($0) }
        view.update(entries: partial, selectionIndex: 42, numbers: [7: "1", 42: "2"], enterConfirmsCandidate: true)
        try button(in: view, identifier: "candidate-tree-toggle").performClick(nil)
        let sharedWord = try XCTUnwrap(descendants(in: view).compactMap { $0 as? TreeButton }.first {
            $0.title == "日本語"
        })
        XCTAssertEqual(sharedWord.candidateNumber, "2")
        sharedWord.performClick(nil)
        XCTAssertEqual(selections, [42], "The badge and word both select the original candidate mapped to number 2")
        XCTAssertTrue(submissions.isEmpty)
        view.update(entries: partial, selectionIndex: 42, numbers: [7: "1", 42: "2"], enterConfirmsCandidate: true)
        let partialRow = try XCTUnwrap(descendants(in: view).compactMap { $0 as? CandidateRowButton }.first {
            $0.candidateIndex == 7
        })
        XCTAssertEqual(partialRow.title, "1. 日本語")
        partialRow.performClick(nil)
        XCTAssertEqual(selections, [42, 7])
        try button(in: view, identifier: "candidate-confirm").performClick(nil)
        XCTAssertEqual(submissions, [7])
    }
}
