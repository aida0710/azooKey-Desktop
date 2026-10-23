import AppKit
@testable import azooKeyMac
import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@MainActor
final class CandidateNavigationViewTests: XCTestCase {
    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            child.isHidden ? [] : ((child as? NSButton).map { [$0] } ?? buttons(in: child))
        }
    }

    func testCrossingAPageBoundaryKeepsNumberKeysOnTheDisplayedPage() throws {
        let preference = Config.TreeCandidates()
        let previous = preference.value
        defer { preference.value = previous }
        preference.value = true
        let controller = CandidatesViewController()
        controller.showCandidateIndex = true
        _ = controller.view
        let candidates = (0..<20).map {
            CandidatePresentation(candidate: Candidate(text: "候補\($0)", value: 0,
                                                       composingCount: .surfaceCount(0), lastMid: 0, data: []))
        }
        controller.updateCandidatePresentations(candidates, selectionIndex: 0, cursorLocation: .zero,
                                                enterConfirmsCandidate: true)
        for _ in 0..<9 { controller.selectNextCandidate() }
        XCTAssertEqual(controller.currentSelectedRow, 9)
        XCTAssertEqual(controller.getNumberCandidate(num: 1), 9)
        XCTAssertEqual(controller.getNumberCandidate(num: 2), 10)
        XCTAssertTrue(buttons(in: controller.view).contains { $0.title == "1. 候補9" })
        XCTAssertTrue(buttons(in: controller.view).contains { $0.title == "2. 候補10" })
        for _ in 0..<9 { controller.selectNextCandidate() }
        XCTAssertEqual(controller.currentSelectedRow, 18)
        XCTAssertEqual(controller.getNumberCandidate(num: 2), 19)
        XCTAssertNil(controller.getNumberCandidate(num: 3))
        XCTAssertNil(controller.getNumberCandidate(num: 9))
        XCTAssertTrue(buttons(in: controller.view).contains { $0.title == "2. 候補19" })
        XCTAssertFalse(buttons(in: controller.view).contains { $0.title.hasPrefix("3. ") })
        controller.hide()
        XCTAssertEqual(controller.getNumberCandidate(num: 1), 0)
    }

    func testPageKeysReachTheLastCandidateWithoutPagingButtons() throws {
        let entries = (0..<500).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        let view = CandidateTreeView()
        var selected: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.update(entries: entries, selectionIndex: 0, enterConfirmsCandidate: true)
        for _ in 0..<55 { XCTAssertTrue(view.movePage(forward: true)) }
        XCTAssertEqual(selected.last, 495)
        for _ in 0..<4 { XCTAssertTrue(view.navigate(.down)) }
        XCTAssertEqual(selected.last, 499)
        XCTAssertTrue(view.movePage(forward: true))
        XCTAssertEqual(selected.last, 499)
        XCTAssertTrue(view.movePage(forward: false))
        XCTAssertEqual(selected.last, 486)
        XCTAssertFalse(buttons(in: view).contains { $0.title == Localization.text("candidate.nextPage") ||
            $0.title == Localization.text("candidate.previousPage") })
    }

    func testChangingPagesDisablesOldRowsAndKeepsSelectionWithinAPage() throws {
        let entries = (0..<20).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        let view = CandidateNavigationView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        var selected: [Int] = []
        view.onSelection = { selected.append($0) }
        view.update(page: CandidatePage(entries: entries, selectionIndex: 0), numbers: [:], fontSize: 14)
        let first = try XCTUnwrap(buttons(in: view).first { $0.title == "候補0" })
        view.update(page: CandidatePage(entries: entries, selectionIndex: 1), numbers: [:], fontSize: 14)
        XCTAssertTrue(buttons(in: view).contains { $0 === first })
        XCTAssertFalse(first.isAccessibilitySelected())
        XCTAssertEqual(buttons(in: view).first { $0.title == "候補1" }?.state, .on)
        view.update(page: CandidatePage(entries: entries, selectionIndex: 9), numbers: [:], fontSize: 14)
        first.performClick(nil)
        XCTAssertTrue(selected.isEmpty)
        try XCTUnwrap(buttons(in: view).first { $0.title == "候補9" }).performClick(nil)
        XCTAssertEqual(selected, [9])
        let current = try XCTUnwrap(buttons(in: view).first { $0.title == "候補9" })
        view.update(page: CandidatePage(entries: [], selectionIndex: nil), numbers: [:], fontSize: 14)
        current.performClick(nil)
        XCTAssertEqual(selected, [9])
    }

    func testNumberShortcutsDisappearWhenTheSameCandidatesBecomeUnnumbered() throws {
        let entries = [
            CandidateTree.Entry(text: "第一案", tokens: [], candidateIndex: 0),
            CandidateTree.Entry(text: "第二案", tokens: [], candidateIndex: 1)
        ]
        let page = CandidatePage(entries: entries, selectionIndex: 0)
        let view = CandidateNavigationView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var selected: [Int] = []
        view.onSelection = { index in selected.append(index) }
        view.update(page: page, numbers: [0: "1", 1: "2"], fontSize: 18)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "1. 第一案" })
        view.update(page: page, numbers: [:], fontSize: 18)
        XCTAssertFalse(buttons(in: view).contains { $0.title.hasPrefix("1. ") || $0.title.hasPrefix("2. ") })
        try XCTUnwrap(buttons(in: view).first { $0.title == "第二案" }).performClick(nil)
        XCTAssertEqual(selected, [1])
    }

    func testLongCandidatesWrapAtBothTextSizesInsteadOfTruncating() throws {
        let word = String(repeating: "長い候補👩‍💻ABC", count: 12)
        let entries = [CandidateTree.Entry(text: word, tokens: [], candidateIndex: 7)]
        let page = CandidatePage(entries: entries, selectionIndex: 7)
        var heights: [CGFloat] = []
        for size: CGFloat in [18, 24] {
            let view = CandidateNavigationView(frame: NSRect(x: 0, y: 0, width: 480, height: 326))
            view.update(page: page, numbers: [7: "1"], fontSize: size)
            view.layoutSubtreeIfNeeded()
            let row = try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }.first)
            XCTAssertEqual(row.title, "1. " + word)
            XCTAssertEqual(row.font?.pointSize, size)
            XCTAssertGreaterThan(row.frame.height, 52)
            XCTAssertEqual(row.frame.height, row.preferredHeight(width: row.frame.width))
            XCTAssertFalse(row.acceptsFirstResponder)
            heights.append(row.frame.height)
        }
        XCTAssertGreaterThan(heights[1], heights[0])
    }

    func testReplacingTheCandidateGenerationRejectsOldAssistiveAndHoverActions() throws {
        let entries = [CandidateTree.Entry(text: "同じ", tokens: [], candidateIndex: 42)]
        let page = CandidatePage(entries: entries, selectionIndex: 42)
        let view = CandidateNavigationView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        var selected: [Int] = []
        var previews: [Int] = []
        view.onSelection = { index in selected.append(index) }
        view.onPreview = { index, _, _ in previews.append(index) }
        view.update(page: page, numbers: [:], fontSize: 18, generation: 1)
        let oldRow = try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }.first)
        view.update(page: page, numbers: [:], fontSize: 18, generation: 2)
        oldRow.performClick(nil)
        oldRow.preview?(true)
        XCTAssertFalse(view.isCurrentCandidateButton(oldRow, candidateIndex: 42))
        XCTAssertTrue(selected.isEmpty)
        XCTAssertTrue(previews.isEmpty)
        try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }.first).performClick(nil)
        XCTAssertEqual(selected, [42])
    }

    func testAISuggestionRowsNeverAdvertiseNumberShortcuts() {
        let controller = ReplaceSuggestionsViewController()
        _ = controller.view
        let suggestions = ["第一案", "第二案"]
        let presentations = suggestions.map {
            CandidatePresentation(candidate: Candidate(text: $0, value: 0,
                                                       composingCount: .surfaceCount(0), lastMid: 0, data: []))
        }
        controller.updateCandidatePresentations(presentations, selectionIndex: 0, cursorLocation: .zero)
        for (row, text) in suggestions.enumerated() {
            let cell = CandidateTableCellView()
            controller.configureCellView(cell, forRow: row)
            XCTAssertEqual(cell.candidateTextField.stringValue, text)
        }
        controller.selectNextCandidate()
        XCTAssertEqual(controller.getSelectedCandidate()?.text, "第二案")
    }
}
