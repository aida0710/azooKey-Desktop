import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class CandidatePresentationStateTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testBothInputPhasesOmitHeadingsDetailsAndActionButtons() {
        let view = CandidateTreeView()
        let entries = [CandidateTree.Entry(text: "候補", tokens: [], candidateIndex: 0)]
        let removedIdentifiers = ["candidate-confirm", "candidate-tree-toggle", "candidate-details-toggle", "candidate-details"]
        let removedKeys = ["candidate.composition", "candidate.proposal", "candidate.selectHint",
                           "candidate.openTree", "candidate.openDetails"]
        for converting in [false, true] {
            view.update(entries: entries, selectionIndex: 0, numbers: [0: "1"], enterConfirmsCandidate: converting)
            let children = descendants(view)
            XCTAssertFalse(children.contains { removedIdentifiers.contains($0.accessibilityIdentifier() ?? "") })
            let labels = children.compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertFalse(removedKeys.contains { labels.contains(Localization.text($0)) })
            let buttons = children.compactMap { $0 as? NSButton }
            XCTAssertTrue(buttons.allSatisfy { $0 is TreeButton || $0 is CandidateRowButton })
            XCTAssertFalse(buttons.contains { $0.acceptsFirstResponder })
            XCTAssertFalse(buttons.contains { ["次へ", "前へ", "確定", "確定 ↵", "この候補を確定"].contains($0.title) })
            XCTAssertEqual(labels.filter { $0.contains("/") }, ["1/1"])
        }
    }

    func testChangingInputPhaseRetiresOldRowsAndTreeActions() throws {
        let view = CandidateTreeView()
        let entries = [CandidateTree.Entry(text: "候補", tokens: [], candidateIndex: 7)]
        var selected: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.update(entries: entries, selectionIndex: 7)
        let oldWord = try XCTUnwrap(descendants(view).compactMap { $0 as? TreeButton }.first)
        view.update(entries: entries, selectionIndex: 7, enterConfirmsCandidate: true)
        oldWord.performClick(nil)
        XCTAssertTrue(selected.isEmpty)
        let oldRow = try XCTUnwrap(descendants(view).compactMap { $0 as? CandidateRowButton }.first)
        oldRow.performClick(nil)
        XCTAssertEqual(selected, [7])
        view.update(entries: entries, selectionIndex: 7)
        oldRow.performClick(nil)
        XCTAssertEqual(selected, [7])
    }

    func testShortRowsFitDesktopSizesAndGrowForLargerText() throws {
        let page = CandidatePage(entries: [.init(text: "日本語", tokens: [], candidateIndex: 0)], selectionIndex: 0)
        var heights: [CGFloat] = []
        for size in Config.CandidateTextSize.Value.allCases {
            let points = MacCandidateMetrics.fontSize(size)
            let row = CandidateRowButton(item: try XCTUnwrap(page.items.first), number: "1", fontSize: points)
            let height = row.preferredHeight(width: 180)
            let font = try XCTUnwrap(row.font)
            XCTAssertGreaterThan(height, font.ascender - font.descender)
            XCTAssertLessThan(height, 36)
            heights.append(height)
        }
        XCTAssertGreaterThan(heights[1], heights[0])
    }
}
