import AppKit
import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest
@testable import azooKeyMac

@MainActor
final class CandidateNavigationViewTests: XCTestCase {
    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            child.isHidden ? [] : ((child as? NSButton).map { [$0] } ?? buttons(in: child))
        }
    }

    func testCrossingAPageBoundaryKeepsNumberKeysOnTheDisplayedPage() {
        let preference = Config.TreeCandidates()
        let previous = preference.value
        defer { preference.value = previous }
        preference.value = true
        let controller = CandidatesViewController()
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
        for _ in 0..<9 { controller.selectNextCandidate() }
        XCTAssertEqual(controller.currentSelectedRow, 18)
        XCTAssertEqual(controller.getNumberCandidate(num: 2), 19)
        XCTAssertNil(controller.getNumberCandidate(num: 3))
        XCTAssertNil(controller.getNumberCandidate(num: 9))
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
}
