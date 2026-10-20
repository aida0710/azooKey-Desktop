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
        controller.updateCandidatePresentations(candidates, selectionIndex: 0, cursorLocation: .zero)
        for _ in 0..<9 { controller.selectNextCandidate() }
        XCTAssertEqual(controller.currentSelectedRow, 9)
        XCTAssertEqual(controller.getNumberCandidate(num: 1), 9)
        XCTAssertEqual(controller.getNumberCandidate(num: 2), 10)
        try XCTUnwrap(buttons(in: controller.view).first {
            $0.title == Localization.text("candidate.openList")
        }).performClick(nil)
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

    func testPointerCanPageToTheLastRealCandidateAndCommitOnce() throws {
        let entries = (0..<500).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        let view = CandidateNavigationView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var commits: [Int] = []
        view.onSelection = { index, submit in
            if submit {
                commits.append(index)
            } else {
                view.update(page: CandidatePage(entries: entries, selectionIndex: index), numbers: [:], fontSize: 18)
            }
        }
        view.update(page: CandidatePage(entries: entries, selectionIndex: 0), numbers: [:], fontSize: 18)
        try XCTUnwrap(buttons(in: view).first { $0.title == Localization.text("candidate.openList") }).performClick(nil)
        let next = try XCTUnwrap(buttons(in: view).first { $0.title == Localization.text("candidate.nextPage") })
        for _ in 0..<56 where next.isEnabled { next.performClick(nil) }
        XCTAssertFalse(next.isEnabled)
        XCTAssertLessThanOrEqual(buttons(in: view).count, 12)
        let last = try XCTUnwrap(buttons(in: view).first { $0.title == "候補499" })
        XCTAssertFalse(last.acceptsFirstResponder)
        last.performClick(nil)
        XCTAssertEqual(commits, [499])
        view.update(page: CandidatePage(entries: [], selectionIndex: nil), numbers: [:], fontSize: 18)
        last.performClick(nil)
        XCTAssertEqual(commits, [499])
    }

    func testClosingTheListDisablesRetainedPageActions() throws {
        let entries = (0..<20).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        let view = CandidateNavigationView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var selected: [Int] = []
        view.onSelection = { index, _ in selected.append(index) }
        view.update(page: CandidatePage(entries: entries, selectionIndex: 0), numbers: [:], fontSize: 18)
        let toggle = try XCTUnwrap(buttons(in: view).first { $0.title == Localization.text("candidate.openList") })
        toggle.performClick(nil)
        let next = try XCTUnwrap(buttons(in: view).first { $0.title == Localization.text("candidate.nextPage") })
        let first = try XCTUnwrap(buttons(in: view).first { $0.title == "候補0" })
        view.update(page: CandidatePage(entries: entries, selectionIndex: 1), numbers: [:], fontSize: 18)
        XCTAssertTrue(buttons(in: view).contains { $0 === first })
        XCTAssertFalse(first.isAccessibilitySelected())
        toggle.performClick(nil)
        next.performClick(nil)
        XCTAssertTrue(selected.isEmpty)
    }

    func testNumberShortcutsDisappearWhenTheSameCandidatesBecomeUnnumbered() throws {
        let entries = [
            CandidateTree.Entry(text: "第一案", tokens: [], candidateIndex: 0),
            CandidateTree.Entry(text: "第二案", tokens: [], candidateIndex: 1)
        ]
        let page = CandidatePage(entries: entries, selectionIndex: 0)
        let view = CandidateNavigationView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var commits: [Int] = []
        view.onSelection = { index, submit in
            if submit { commits.append(index) }
        }
        view.update(page: page, numbers: [0: "1", 1: "2"], fontSize: 18)
        try XCTUnwrap(buttons(in: view).first {
            $0.title == Localization.text("candidate.openList")
        }).performClick(nil)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "1. 第一案" })
        view.update(page: page, numbers: [:], fontSize: 18)
        XCTAssertFalse(buttons(in: view).contains { $0.title.hasPrefix("1. ") || $0.title.hasPrefix("2. ") })
        try XCTUnwrap(buttons(in: view).first { $0.title == "第二案" }).performClick(nil)
        XCTAssertEqual(commits, [1])
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
