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

    func testEnglishAndJapaneseDefinitionsWrapAndCardFitsTheVisibleLines() throws {
        for fontSize: CGFloat in [12, 16] {
            for text in [
                "A procedure intended to establish the quality of something.",
                "物事の性質や能力を確かめるために行う試験や検査。"
            ] {
                let card = WordDefinitionsSideView(frame: .zero)
                card.update(word: "test", result: .definition("短文"), fontSize: fontSize)
                let singleLineHeight = card.preferredHeight
                card.update(word: "test", result: .definition(text), fontSize: fontSize)
                let summary = try summaryField(in: card)
                layout(card)

                XCTAssertEqual(summary.lineBreakMode, .byWordWrapping)
                XCTAssertGreaterThan(card.preferredHeight, singleLineHeight, text)
                XCTAssertLessThan(summary.frame.height, height(of: 5, in: summary), text)
                XCTAssertEqual(summary.frame.height, ceil(summary.sizeThatFits(
                    NSSize(width: summary.bounds.width, height: .greatestFiniteMagnitude)).height))
                XCTAssertTrue(card.bounds.contains(summary.frame))
                let heading = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first { $0 !== summary })
                XCTAssertEqual(summary.frame.maxY, heading.frame.minY)
                XCTAssertEqual(summary.frame.minY, card.bounds.maxY - heading.frame.maxY)
                XCTAssertEqual(summary.frame.minX, card.bounds.maxX - summary.frame.maxX)
            }
        }
    }

    func testLongDefinitionsStopAtFiveLinesAndShrinkWhenReplaced() throws {
        for fontSize: CGFloat in [12, 16] {
            for text in [String(repeating: "mmmm ", count: 100), String(repeating: "長い説明です。", count: 100)] {
                let card = WordDefinitionsSideView(frame: .zero)
                card.update(word: "test", result: .definition(text), fontSize: fontSize)
                let summary = try summaryField(in: card)
                layout(card)
                let cappedHeight = card.preferredHeight

                XCTAssertEqual(summary.maximumNumberOfLines, 5)
                XCTAssertEqual(summary.cell?.truncatesLastVisibleLine, true)
                XCTAssertEqual(summary.frame.height, height(of: 5, in: summary))
                let unlimited = NSTextField(wrappingLabelWithString: summary.stringValue)
                unlimited.font = summary.font
                XCTAssertGreaterThan(unlimited.sizeThatFits(NSSize(width: summary.bounds.width,
                    height: .greatestFiniteMagnitude)).height, summary.frame.height)

                card.update(word: "test", result: .definition("短文"), fontSize: fontSize)
                layout(card)
                XCTAssertEqual(summary.frame.height, height(of: 1, in: summary))
                XCTAssertLessThan(card.preferredHeight, cappedHeight)
            }
        }
    }

    func testLongEnglishDefinitionDrawsFiveLinesAndAnEllipsis() throws {
        let card = WordDefinitionsSideView(frame: .zero)
        card.update(word: "test", result: .definition(String(repeating: "mmmm ", count: 100)), fontSize: 16)
        layout(card)
        let summary = try summaryField(in: card)
        let truncated = try drawSummary(summary)
        var visibleLines = 0
        var previousRowContainsText = false
        for row in 0..<truncated.pixelsHigh {
            let containsText = (0..<truncated.pixelsWide).contains { column in
                (truncated.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.25
            }
            if containsText && !previousRowContainsText { visibleLines += 1 }
            previousRowContainsText = containsText
        }
        XCTAssertEqual(visibleLines, 5, "The rendered cell must contain five separate lines of text")
        summary.cell?.truncatesLastVisibleLine = false
        let clipped = try drawSummary(summary)
        XCTAssertNotEqual(truncated.representation(using: .png, properties: [:]),
                          clipped.representation(using: .png, properties: [:]),
                          "Overflow must draw an ellipsis rather than only clipping the text")
    }

    func testDefinitionAtLastRowStaysInsideAHeightConstrainedCandidateView() throws {
        let availability = WordDefinitionsAvailabilityModel(check: { words, completion in
            completion(words.map { _ in true })
        }, cancel: {})
        let model = WordDefinitionsModel(search: { _, completion in
            completion(String(repeating: "長い説明です。", count: 100))
        }, cancelPending: {}, availability: availability)
        let view = CandidateTreeView(frame: .zero, definitions: model)
        let entries = (0..<7).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        view.update(entries: entries, selectionIndex: 6, enterConfirmsCandidate: true)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(descendants(view).compactMap { $0 as? WordDefinitionsSideView }.first)
        let list = try XCTUnwrap(descendants(view).compactMap { $0 as? CandidateNavigationView }.first)
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(view.bounds.height - card.frame.maxY, list.selectedRowTop)
        XCTAssertEqual(card.frame.height, card.preferredHeight)
        XCTAssertTrue(view.bounds.contains(card.frame))

        for availableHeight in [card.preferredHeight + list.selectedRowTop / 2, card.preferredHeight / 2] {
            view.setFrameSize(NSSize(width: view.preferredSize.width, height: availableHeight))
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(view.bounds.contains(card.frame))
            XCTAssertEqual(card.frame.minY, 0)
            XCTAssertEqual(card.frame.height, min(availableHeight, card.preferredHeight))
        }
    }

    private func summaryField(in card: WordDefinitionsSideView) throws -> NSTextField {
        try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first { $0.maximumNumberOfLines > 1 })
    }

    private func layout(_ card: WordDefinitionsSideView) {
        card.setFrameSize(NSSize(width: MacCandidateMetrics.definitionWidth, height: card.preferredHeight))
        card.layoutSubtreeIfNeeded()
    }

    private func height(of lines: Int, in summary: NSTextField) -> CGFloat {
        let reference = NSTextField(wrappingLabelWithString: Array(repeating: String(summary.stringValue.prefix(1)), count: lines).joined(separator: "\n"))
        reference.font = summary.font
        return ceil(reference.sizeThatFits(NSSize(width: summary.bounds.width, height: .greatestFiniteMagnitude)).height)
    }

    private func drawSummary(_ summary: NSTextField) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(summary.bounds.width)), pixelsHigh: Int(ceil(summary.bounds.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        summary.bounds.fill(using: .copy)
        summary.textColor = .black
        try XCTUnwrap(summary.cell).draw(withFrame: summary.bounds, in: summary)
        return bitmap
    }
}
