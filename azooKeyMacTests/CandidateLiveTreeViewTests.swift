import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class CandidateLiveTreeViewTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testLiveTreeHasCompactWordsWithoutNumberBadgesAndStillSelectsRealCandidates() throws {
        let preference = Config.CandidateTextSize()
        let previous = preference.value
        defer { preference.value = previous }
        let entries: [CandidateTree.Entry] = [
            .init(text: "日本語", tokens: [.init(text: "日本"), .init(text: "語")], candidateIndex: 7),
            .init(text: "日本画", tokens: [.init(text: "日本"), .init(text: "画")], candidateIndex: 42)
        ]
        for size in Config.CandidateTextSize.Value.allCases {
            preference.value = size
            let view = CandidateTreeView()
            var selections: [Int] = []
            view.onSelectionChanged = { selections.append($0) }
            view.update(entries: entries, selectionIndex: 7, numbers: [7: "1", 42: "2"])
            view.setFrameSize(view.preferredSize)
            view.layoutSubtreeIfNeeded()
            let words = descendants(view).compactMap { $0 as? TreeButton }
            XCTAssertEqual(Set(words.map(\.title)), ["日本", "語", "画"])
            for word in words {
                XCTAssertEqual(word.font?.pointSize, MacCandidateMetrics.fontSize(size))
                XCTAssertLessThan(word.frame.height, 36)
                XCTAssertTrue(word.bounds.contains(word.candidateTextFrame))
            }
            XCTAssertLessThan(view.preferredSize.width, 200)
            XCTAssertLessThan(view.preferredSize.height, 100)
            try XCTUnwrap(words.first { $0.title == "画" }).performClick(nil)
            XCTAssertEqual(selections, [42])
            view.update(entries: entries, selectionIndex: 42, numbers: [7: "1", 42: "2"], enterConfirmsCandidate: true)
            XCTAssertTrue(descendants(view).compactMap { $0 as? TreeButton }.isEmpty)
            XCTAssertEqual(descendants(view).compactMap { $0 as? CandidateRowButton }.map(\.title), ["1. 日本語", "2. 日本画"])
        }
    }
}
