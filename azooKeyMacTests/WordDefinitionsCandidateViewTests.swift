import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class WordDefinitionsCandidateViewTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testDefinitionAppearsOnSelectionAndMissingCandidateRemovesCardAndWidth() throws {
        var searches: [String] = []
        var completions: [WordDefinitionsService.Completion] = []
        let availability = WordDefinitionsAvailabilityModel(check: { _, completion in completion([true, false]) }, cancel: {})
        let model = WordDefinitionsModel(search: { word, completion in
            searches.append(word)
            completions.append(completion)
        }, cancelPending: {}, availability: availability)
        let view = CandidateTreeView(frame: .zero, definitions: model)
        let entries: [CandidateTree.Entry] = [
            .init(text: "test", tokens: [], candidateIndex: 7),
            .init(text: "qzxv", tokens: [], candidateIndex: 42)
        ]
        var selections: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.update(entries: entries, selectionIndex: 7, numbers: [7: "1", 42: "2"], enterConfirmsCandidate: true)
        let widthWithoutDefinition = view.preferredSize.width
        let card = try XCTUnwrap(descendants(view).compactMap { $0 as? WordDefinitionsSideView }.first)
        XCTAssertTrue(card.isHidden)
        XCTAssertEqual(searches, ["test"])
        completions[0]("A procedure intended to establish the quality of something.")
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(card.isHidden)
        let list = try XCTUnwrap(descendants(view).compactMap { $0 as? CandidateNavigationView }.first)
        XCTAssertGreaterThan(card.frame.minX, list.frame.maxX)
        XCTAssertEqual(view.preferredSize.width, widthWithoutDefinition + MacCandidateMetrics.cardGap + MacCandidateMetrics.definitionWidth)
        let rows = descendants(view).compactMap { $0 as? CandidateRowButton }
        XCTAssertEqual(rows.filter(\.hasDefinition).map(\.candidateIndex), [7])
        XCTAssertTrue(selections.isEmpty)
        try XCTUnwrap(rows.first { $0.candidateIndex == 42 }).performClick(nil)
        XCTAssertEqual(selections, [42])
        XCTAssertTrue(card.isHidden, "A pending lookup must not keep the previous word's explanation")
        XCTAssertEqual(view.preferredSize.width, widthWithoutDefinition)
        completions[1](nil)
        XCTAssertTrue(card.isHidden)
        XCTAssertEqual(view.preferredSize.width, widthWithoutDefinition)
        completions[0]("Stale result")
        XCTAssertTrue(card.isHidden)
        view.update(entries: [], selectionIndex: nil)
        completions[1]("A result after dismissal")
        XCTAssertTrue(card.isHidden)
        XCTAssertNil(model.target)
    }

    func testDefinitionStaysShortAndDoesNotOfferDetailsOrTakeFocus() throws {
        let card = WordDefinitionsSideView(frame: .zero)
        card.update(word: "辞書", result: .definition(String(repeating: "長い説明です。", count: 100)), fontSize: 14)
        card.setFrameSize(NSSize(width: MacCandidateMetrics.definitionWidth, height: card.preferredHeight))
        card.layoutSubtreeIfNeeded()
        XCTAssertLessThan(card.preferredHeight, 120)
        XCTAssertLessThan(try XCTUnwrap(card.accessibilityLabel()).count, 190)
        XCTAssertTrue(descendants(card).compactMap { $0 as? NSButton }.isEmpty)
        XCTAssertFalse(card.acceptsFirstResponder)
        card.update(word: "不明", result: .notFound, fontSize: 14)
        XCTAssertFalse(card.hasDefinition)
        XCTAssertEqual(card.accessibilityLabel(), "")
    }
}
