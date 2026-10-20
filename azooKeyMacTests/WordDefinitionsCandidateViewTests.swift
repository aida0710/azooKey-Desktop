import AppKit
import Core
import XCTest

@testable import azooKeyMac

@MainActor
final class WordDefinitionsCandidateViewTests: XCTestCase {
    func testLiveTreeDoesNotSearchOrGrowUntilTheConversionMenuIsShown() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: false)
        XCTAssertTrue(fixture.words.isEmpty)
        XCTAssertTrue(try summary(in: view).isHidden)
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        XCTAssertEqual(fixture.words, ["橋"])
        XCTAssertFalse(try summary(in: view).isHidden)
        XCTAssertEqual(fixture.model.target?.candidateIndex, 42)
    }

    func testWordDepthAndFullRowHoverUseThatCandidatesActualPathWithoutSelectingIt() throws {
        let fixture = Fixture()
        let view = fixture.view()
        var selections: [Int] = []
        var submissions: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.onCandidateSubmitted = { submissions.append($0) }
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        _ = view.navigate(.right)
        XCTAssertEqual(fixture.model.target?.word, "を渡る")
        let row = try XCTUnwrap(descendants(view).compactMap { $0 as? CandidateRowButton }.first { $0.candidateIndex == 7 })
        row.preview?(true)
        XCTAssertEqual(fixture.model.target?.word, "橋")
        XCTAssertEqual(fixture.model.target?.candidateIndex, 7)
        XCTAssertEqual(fixture.model.target?.reading, "ハシ")
        XCTAssertTrue(selections.isEmpty)
        XCTAssertTrue(submissions.isEmpty)
    }

    func testOldHoverControlAndOldDefinitionCannotReplaceTheNewCandidate() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        let oldRow = try XCTUnwrap(descendants(view).compactMap { $0 as? CandidateRowButton }.first)
        view.update(entries: [.init(text: "箸", tokens: [.init(text: "箸", reading: "ハシ")], candidateIndex: 42)],
                    selectionIndex: 42, enterConfirmsCandidate: true)
        let requestCount = fixture.words.count
        oldRow.preview?(true)
        fixture.completions[0]("古い橋の説明")
        XCTAssertEqual(fixture.words.count, requestCount)
        XCTAssertEqual(fixture.model.target?.word, "箸")
        XCTAssertEqual(fixture.model.result, .loading)
    }

    func testHidingOrChangingBackToLiveDiscardsThePendingDefinition() {
        let fixture = Fixture()
        let view = fixture.view()
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        view.setDefinitionsEnabled(false)
        fixture.completions[0]("閉じた後の説明")
        XCTAssertNil(fixture.model.result)
        view.setDefinitionsEnabled(true)
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: false)
        fixture.completions.last?("ライブへ戻った後の説明")
        XCTAssertNil(fixture.model.result)
    }

    func testTemplatesUseTheirVisiblePhraseWithoutGuessingWordBoundaries() {
        let fixture = Fixture()
        let view = fixture.view()
        let phrase = "変換結果そのものの合成文"
        view.update(entries: [.init(text: phrase, tokens: [.init(text: "別の辞書項目", reading: "ベツ")], candidateIndex: 12)],
                    selectionIndex: 12, enterConfirmsCandidate: true)
        XCTAssertEqual(fixture.words, [phrase])
        XCTAssertEqual(fixture.model.target?.reading, "")
    }

    func testFullDefinitionAndTruthfulSourceRemainReadableInTheExistingDetails() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        let full = "語の説明\n合成した用例。\n" + String(repeating: "長い説明。", count: 100)
        fixture.completions[0](full)
        let details = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier() == "candidate-details" } as? CandidateDetailView)
        let text = try XCTUnwrap(descendants(details).compactMap { $0 as? NSTextField }.first).stringValue
        XCTAssertTrue(text.contains(full))
        XCTAssertTrue(text.contains(Localization.text("candidate.definition.source")))
        XCTAssertTrue(text.contains(Localization.text("candidate.definition.readingNote")))
        let label = try summary(in: view)
        XCTAssertFalse(label.acceptsFirstResponder)
        for fontSize: CGFloat in [18, 24] {
            label.update(target: fixture.model.target, result: fixture.model.result, fontSize: fontSize)
            XCTAssertLessThanOrEqual(label.preferredHeight, 80)
            label.frame = NSRect(x: 0, y: 0, width: 480, height: label.preferredHeight)
            label.layoutSubtreeIfNeeded()
            let fields = descendants(label).compactMap { $0 as? NSTextField }
            XCTAssertTrue(fields.allSatisfy { !$0.isSelectable })
            let source = try XCTUnwrap(fields.first { $0.stringValue == Localization.text("candidate.definition.source") })
            let title = try XCTUnwrap(fields.first { $0.font?.pointSize == fontSize && $0.frame.minY > 6 })
            let summary = try XCTUnwrap(fields.first { $0.font?.pointSize == fontSize && $0.frame.minY == 6 })
            XCTAssertLessThanOrEqual(title.frame.maxX, source.frame.minX)
            XCTAssertEqual(title.frame.midY, source.frame.midY)
            XCTAssertLessThanOrEqual(summary.frame.maxY, title.frame.minY)
            XCTAssertEqual(source.accessibilityHelp(), Localization.text("candidate.definition.detailsHint"))
        }
    }

    func testScaledSummaryKeepsWholeLinesWithinBoundsWithoutShrinkingTheCandidateFont() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        fixture.completions[0]("現在の語の説明")
        let label = try summary(in: view)
        for fontSize: CGFloat in [18, 24] {
            label.update(target: fixture.model.target, result: fixture.model.result, fontSize: fontSize)
            let preferredHeight = label.preferredHeight
            for height in [CGFloat.zero, 20, preferredHeight / 2, preferredHeight] {
                label.frame = NSRect(x: 0, y: 0, width: 320, height: height)
                label.layoutSubtreeIfNeeded()
                let visible = descendants(label).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
                XCTAssertTrue(visible.allSatisfy { label.bounds.contains($0.frame) })
                XCTAssertTrue(visible.filter { $0.font?.pointSize != 12 }.allSatisfy { $0.font?.pointSize == fontSize })
                if height == preferredHeight / 2 {
                    XCTAssertEqual(visible.count, 1)
                    XCTAssertTrue(try XCTUnwrap(visible.first).stringValue.contains("現在の語の説明"))
                } else if height == preferredHeight {
                    XCTAssertEqual(visible.count, 3)
                } else {
                    XCTAssertTrue(visible.isEmpty)
                }
                XCTAssertTrue(label.detailDescription.contains("現在の語の説明"))
            }
        }
    }

    private func summary(in view: NSView) throws -> WordDefinitionsSummaryView {
        try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier() == "candidate-definition-summary" } as? WordDefinitionsSummaryView)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @MainActor
    private final class Fixture {
        let entries: [CandidateTree.Entry] = [
            .init(text: "橋", tokens: [.init(text: "橋", reading: "ハシ")], candidateIndex: 7),
            .init(text: "橋を渡る", tokens: [.init(text: "橋", reading: "ハシ"), .init(text: "を渡る", reading: "ヲワタル")], candidateIndex: 42)
        ]
        var words: [String] = []
        var completions: [WordDefinitionsService.Completion] = []
        lazy var model = WordDefinitionsModel(search: { [weak self] in
            self?.words.append($0)
            self?.completions.append($1)
        }, cancelPending: {})

        func view() -> CandidateTreeView {
            CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 600), definitions: model)
        }
    }
}
