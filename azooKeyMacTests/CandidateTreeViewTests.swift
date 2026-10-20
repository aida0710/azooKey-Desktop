import AppKit
@testable import azooKeyMac
import Core
import XCTest

@MainActor
final class CandidateTreeViewTests: XCTestCase {
    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            child.isHidden ? [] : ((child as? NSButton).map { [$0] } ?? buttons(in: child))
        }
    }

    private func candidateButtons(in view: CandidateTreeView) -> [NSButton] {
        view.subviews.filter { $0.accessibilityIdentifier() == "candidate-segments" }.flatMap { buttons(in: $0) }
    }

    private let entries: [CandidateTree.Entry] = [
        .init(text: "日本語", tokens: [.init(text: "日本"), .init(text: "語")], candidateIndex: 0),
        .init(text: "日本画", tokens: [.init(text: "日本"), .init(text: "画")], candidateIndex: 1)
    ]

    private let partialEntries: [CandidateTree.Entry] = [
        .init(text: "日本語", tokens: [.init(text: "日本語", reading: "ニホンゴ")], candidateIndex: 0,
              scope: .init(consumedReading: "にほんご", remainingReading: "にゅうりょく")),
        .init(text: "日本語入力", tokens: [.init(text: "日本語", reading: "ニホンゴ"), .init(text: "入力")],
              candidateIndex: 1, annotation: "全文の注釈",
              scope: .init(consumedReading: "にほんごにゅうりょく", remainingReading: "")),
        .init(text: "日本語入力", tokens: [.init(text: "日本語", reading: "ニホンゴ"), .init(text: "入力")],
              candidateIndex: 2, annotation: "別候補の注釈",
              scope: .init(consumedReading: "にほんごにゅうりょく", remainingReading: ""))
    ]

    private func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { child in
            (child as? NSTextField).map { [$0] } ?? textFields(in: child)
        }
    }

    private func detailText(in view: NSView) -> String {
        let details = view.subviews.first { $0.accessibilityIdentifier() == "candidate-details" } ?? view
        return textFields(in: details).map(\.stringValue).joined(separator: "\n")
    }

    private func openTree(in view: CandidateTreeView, file: StaticString = #filePath, line: UInt = #line) {
        let toggle = buttons(in: view).first { $0.title == Localization.text("candidate.openTree") }
        XCTAssertNotNil(toggle, file: file, line: line)
        toggle?.performClick(nil)
    }

    private func confirm(in view: CandidateTreeView, file: StaticString = #filePath, line: UInt = #line) {
        let button = buttons(in: view).first { $0.accessibilityLabel() == Localization.text("candidate.submit") }
        XCTAssertNotNil(button, file: file, line: line)
        button?.performClick(nil)
    }

    private func hoverEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }

    private func assertPartialPreview(in view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let preview = detailText(in: view)
        XCTAssertTrue(preview.contains("確定予定: 日本語\n"), file: file, line: line)
        XCTAssertTrue(preview.contains("にゅうりょく"), file: file, line: line)
        XCTAssertFalse(preview.contains("全文の注釈"), file: file, line: line)
        XCTAssertFalse(preview.contains("別候補の注釈"), file: file, line: line)
    }

    func testLargeCandidateTextRetainsTheFullReadingWithoutCommitting() throws {
        let preference = Config.CandidateTextSize()
        let previous = preference.value
        defer { preference.value = previous }
        preference.value = .large
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        let word = String(repeating: "長い候補👩‍💻ABC", count: 10)
        let reading = String(repeating: "ナガイコウホ", count: 10)
        view.update(entries: [.init(text: word, tokens: [.init(text: word, reading: reading)], candidateIndex: 0)],
                    selectionIndex: 0, documentWidths: [6])
        openTree(in: view)
        view.layoutSubtreeIfNeeded()
        let candidate = try XCTUnwrap(buttons(in: view).first { $0.title == word })
        XCTAssertGreaterThanOrEqual(candidate.font?.pointSize ?? 0, 24)
        XCTAssertGreaterThan(candidate.frame.width, 6)
        XCTAssertTrue(textFields(in: view).contains { $0.stringValue.contains(word) && $0.stringValue.contains(reading) })
        XCTAssertTrue(view.scrollDetails(forward: true))
        XCTAssertFalse(candidate.acceptsFirstResponder)
        XCTAssertEqual(submitted, [])
    }

    func testKeyboardDetailsUseTheExactCandidateAndItsAnnotation() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: [
            .init(text: "日本語入力", tokens: [.init(text: "日本語"), .init(text: "入力")], candidateIndex: 0),
            .init(text: "日本画鑑賞", tokens: [.init(text: "日本画"), .init(text: "鑑賞")],
                  candidateIndex: 1, annotation: "注釈の例",
                  scope: .init(consumedReading: "にほんがかんしょう", remainingReading: "する"))
        ], selectionIndex: 0)
        XCTAssertTrue(view.navigate(.down))
        let details = textFields(in: view).map(\.stringValue).joined()
        XCTAssertTrue(details.contains("日本画鑑賞"))
        XCTAssertTrue(details.contains("にほんがかんしょう"))
        XCTAssertTrue(details.contains("する"))
        XCTAssertTrue(details.contains("注釈の例"))
        XCTAssertEqual(submitted, [])
        XCTAssertTrue(view.navigate(.up))
        XCTAssertFalse(textFields(in: view).map(\.stringValue).joined().contains("注釈の例"))
    }

    func testHoveringANumberPreviewsItsPartialCandidateAndSelectingThenConfirmingCommitsItOnce() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        var submitted: [Int] = []
        var selected: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.onSelectionChanged = { selected.append($0) }
        view.update(entries: Array(partialEntries.prefix(2)), selectionIndex: 1, numbers: [0: "1", 1: "2"])
        openTree(in: view)
        view.layoutSubtreeIfNeeded()
        let word = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "日本語" })
        let number = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "1" })
        let entered = try hoverEvent(.mouseEntered)
        word.mouseEntered(with: entered)
        XCTAssertTrue(textFields(in: view).contains { $0.stringValue.contains("全文の注釈") })
        number.mouseEntered(with: entered)
        let details = textFields(in: view).map(\.stringValue).joined(separator: "\n")
        XCTAssertTrue(details.contains("確定予定: 日本語\n"))
        XCTAssertTrue(details.contains("にゅうりょく"))
        XCTAssertFalse(details.contains("全文の注釈"))
        XCTAssertTrue(number.accessibilityHelp()?.contains("にゅうりょく") == true)
        word.mouseEntered(with: entered)
        XCTAssertTrue(textFields(in: view).contains { $0.stringValue.contains("全文の注釈") })
        number.mouseEntered(with: entered)
        XCTAssertEqual(submitted, [])
        XCTAssertEqual(selected, [])
        XCTAssertFalse(number.acceptsFirstResponder)
        number.performClick(nil)
        XCTAssertEqual(submitted, [])
        XCTAssertEqual(selected, [0])
        confirm(in: view)
        XCTAssertEqual(submitted, [0])
    }

    func testNumberHoverSurvivesSelectionUpdatesAndExitRestoresKeyboardDetails() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        var submitted: [Int] = []
        var selected: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.onSelectionChanged = { selected.append($0) }
        let numbers = [0: "1", 1: "2", 2: "3"]
        view.update(entries: partialEntries, selectionIndex: 1, numbers: numbers)
        openTree(in: view)
        let word = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "日本語" })
        let number = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "1" })
        word.mouseEntered(with: try hoverEvent(.mouseEntered))
        number.mouseEntered(with: try hoverEvent(.mouseEntered))
        // A queued exit from the word must not dismiss the newer number preview.
        word.mouseExited(with: try hoverEvent(.mouseExited))
        for index in [2, 1] {
            view.update(entries: partialEntries, selectionIndex: index, numbers: numbers)
            XCTAssertTrue(candidateButtons(in: view).first { $0.title == "1" } === number)
            assertPartialPreview(in: view)
        }
        number.mouseExited(with: try hoverEvent(.mouseExited))
        XCTAssertTrue(detailText(in: view).contains("全文の注釈"))
        XCTAssertFalse(detailText(in: view).contains("別候補の注釈"))
        XCTAssertEqual(submitted, [])
        XCTAssertEqual(selected, [])
        number.performClick(nil)
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        XCTAssertEqual(submitted, [0])
    }

    func testWordHoverUsesCurrentCandidateAndExitReturnsToTheKeyboardNode() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        view.update(entries: partialEntries, selectionIndex: 1)
        openTree(in: view)
        let word = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "日本語" })
        word.mouseEntered(with: try hoverEvent(.mouseEntered))
        view.update(entries: partialEntries, selectionIndex: 2)
        XCTAssertTrue(view.navigate(.right))
        XCTAssertTrue(detailText(in: view).hasPrefix("日本語\nニホンゴ\n"))
        XCTAssertTrue(detailText(in: view).contains("別候補の注釈"))
        XCTAssertFalse(detailText(in: view).contains("全文の注釈"))
        word.mouseExited(with: try hoverEvent(.mouseExited))
        XCTAssertTrue(detailText(in: view).hasPrefix("入力\n"))
        XCTAssertTrue(detailText(in: view).contains("別候補の注釈"))
    }

    func testRemovedControlsCannotPreviewCandidatesThatReuseTheirIndices() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: partialEntries, selectionIndex: 1, numbers: [0: "1", 1: "2", 2: "3"])
        openTree(in: view)
        let oldWord = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "日本語" })
        let oldNumber = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "1" })
        oldNumber.mouseEntered(with: try hoverEvent(.mouseEntered))
        view.update(entries: [
            .init(text: "別の候補", tokens: [], candidateIndex: 0),
            .init(text: "現在の候補", tokens: [], candidateIndex: 1)
        ], selectionIndex: 1, numbers: [0: "1", 1: "2"])
        for oldControl in [oldWord, oldNumber] {
            oldControl.mouseEntered(with: try hoverEvent(.mouseEntered))
            oldControl.mouseExited(with: try hoverEvent(.mouseExited))
            oldControl.performClick(nil)
        }
        XCTAssertTrue(detailText(in: view).contains("確定予定: 現在の候補"))
        XCTAssertFalse(detailText(in: view).contains("確定予定: 別の候補"))
        XCTAssertFalse(detailText(in: view).contains("日本語"))
        XCTAssertEqual(submitted, [])
        view.update(entries: [], selectionIndex: nil)
        oldNumber.mouseEntered(with: try hoverEvent(.mouseEntered))
        XCTAssertFalse(detailText(in: view).contains("確定予定:"))
    }

    func testRemovingANumberDuringSelectionUpdateReturnsToCurrentDetails() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        view.update(entries: partialEntries, selectionIndex: 1, numbers: [0: "1", 1: "2", 2: "3"])
        openTree(in: view)
        let number = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "1" })
        number.mouseEntered(with: try hoverEvent(.mouseEntered))
        view.update(entries: partialEntries, selectionIndex: 2, numbers: [2: "3"])
        XCTAssertNil(number.superview)
        XCTAssertTrue(detailText(in: view).contains("別候補の注釈"))
        number.mouseEntered(with: try hoverEvent(.mouseEntered))
        XCTAssertTrue(detailText(in: view).contains("別候補の注釈"))
    }

    func testListHoverSurvivesSelectionUpdatesAndExitRestoresKeyboardDetails() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 520))
        let numbers = [0: "1", 1: "2", 2: "3"]
        view.update(entries: partialEntries, selectionIndex: 1, numbers: numbers)
        let list = try XCTUnwrap(view.subviews.compactMap { $0 as? CandidateNavigationView }.first)
        let row = try XCTUnwrap(buttons(in: list).first { $0.title == "1. 日本語" })
        row.mouseEntered(with: try hoverEvent(.mouseEntered))
        for index in [2, 1] {
            view.update(entries: partialEntries, selectionIndex: index, numbers: numbers)
            XCTAssertTrue(buttons(in: list).first { $0.title == "1. 日本語" } === row)
            assertPartialPreview(in: view)
        }
        row.mouseExited(with: try hoverEvent(.mouseExited))
        XCTAssertTrue(detailText(in: view).contains("全文の注釈"))
    }

    func testLeavingAListPageInvalidatesThePreviousRowsPreviewAndActions() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 520))
        let entries = (0..<12).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 1, numbers: [0: "1", 1: "2"])
        let list = try XCTUnwrap(view.subviews.compactMap { $0 as? CandidateNavigationView }.first)
        let row = try XCTUnwrap(buttons(in: list).first { $0.title == "1. 候補0" })
        row.mouseEntered(with: try hoverEvent(.mouseEntered))
        XCTAssertTrue(detailText(in: view).contains("確定予定: 候補0"))
        view.update(entries: entries, selectionIndex: 10, numbers: [9: "1", 10: "2", 11: "3"])
        XCTAssertNil(row.superview)
        row.mouseEntered(with: try hoverEvent(.mouseEntered))
        row.mouseExited(with: try hoverEvent(.mouseExited))
        row.performClick(nil)
        XCTAssertTrue(detailText(in: view).contains("確定予定: 候補10"))
        XCTAssertFalse(detailText(in: view).contains("確定予定: 候補0"))
        XCTAssertEqual(submitted, [])
    }

    func testScoresExplainRelativeMeaningAndRefreshOnCandidateChange() throws {
        let view = CandidateTreeView()
        let scored: [CandidateTree.Entry] = [
            .init(text: "選択", tokens: [.init(text: "選択", reading: "センタク")], candidateIndex: 0, score: log(69)),
            .init(text: "洗濯", tokens: [.init(text: "洗濯", reading: "センタク")], candidateIndex: 1, score: log(31))
        ]
        view.update(entries: scored, selectionIndex: 0)
        openTree(in: view)
        let selection = try XCTUnwrap(buttons(in: view).first { $0.title == "選択" })
        XCTAssertTrue(selection.toolTip?.contains("相対スコア 69") == true)
        XCTAssertEqual(selection.accessibilityLabel(), "選択（センタク）")
        XCTAssertTrue(selection.accessibilityHelp()?.contains("確率ではありません") == true)
        view.update(entries: entries, selectionIndex: 0)
        XCTAssertFalse(buttons(in: view).contains { $0.toolTip?.contains("相対スコア 69") == true })
    }

    func testHidingScoresPreservesTheFocusedCandidateAndExplicitCommit() throws {
        let preference = Config.ShowRelativeScores()
        let previous = preference.value
        defer { preference.value = previous }
        preference.value = true
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        let scored: [CandidateTree.Entry] = [
            .init(text: "選択", tokens: [.init(text: "選択", reading: "センタク")], candidateIndex: 0, score: log(69)),
            .init(text: "洗濯", tokens: [.init(text: "洗濯", reading: "センタク")], candidateIndex: 1, score: log(31))
        ]
        view.update(entries: scored, selectionIndex: 0, numbers: [0: "1"], documentWidths: [80])
        openTree(in: view)
        let chosen = try XCTUnwrap(buttons(in: view).first { $0.title == "選択" })
        let focus = chosen.accessibilityValue() as? String
        let height = view.preferredSize.height
        let explanation = CandidateScorePresentation.explanation
        XCTAssertTrue(textFields(in: view).contains { $0.stringValue.contains(explanation) })
        preference.value = false
        view.update(entries: scored, selectionIndex: 0, numbers: [0: "1"], documentWidths: [80])
        XCTAssertTrue(buttons(in: view).first { $0.title == "選択" } === chosen)
        XCTAssertEqual(chosen.accessibilityValue() as? String, focus)
        XCTAssertTrue(chosen.isAccessibilitySelected())
        XCTAssertFalse(chosen.acceptsFirstResponder)
        XCTAssertFalse(chosen.accessibilityHelp()?.contains(explanation) == true)
        XCTAssertFalse(textFields(in: view).contains { $0.stringValue.contains(explanation) })
        XCTAssertLessThan(view.preferredSize.height, height)
        let number = try XCTUnwrap(buttons(in: view).first { $0.title == "1" })
        XCTAssertGreaterThanOrEqual(number.frame.minY, chosen.frame.maxY)
        XCTAssertEqual(submitted, [])
        chosen.performClick(nil)
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        XCTAssertEqual(submitted, [0])
    }

    func testLongAlternativeDoesNotMoveFollowingWords() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        let before = try XCTUnwrap(buttons(in: view).first { $0.title == "語" }).frame.minX
        view.update(entries: entries + [
            .init(text: "にほんごにゅうりょく", tokens: [], candidateIndex: 2)
        ], selectionIndex: 0)
        let after = try XCTUnwrap(buttons(in: view).first { $0.title == "語" }).frame.minX
        XCTAssertEqual(after, before, "A whole-sentence alternative must not widen the first word's column")
    }

    func testDocumentWidthsKeepEveryBranchInItsWordColumn() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        view.update(entries: entries, selectionIndex: 0, documentWidths: [64, 40])
        openTree(in: view)
        let controls = buttons(in: view)
        let first = try XCTUnwrap(controls.first { $0.title == "日本" })
        let chosen = try XCTUnwrap(controls.first { $0.title == "語" })
        let alternative = try XCTUnwrap(controls.first { $0.title == "画" })
        XCTAssertEqual(chosen.frame.minX - first.frame.minX, 64)
        XCTAssertEqual(alternative.frame.minX, chosen.frame.minX)
        XCTAssertEqual(alternative.frame.width, 40)
    }

    func testAlignedLongSentenceDoesNotScrollAndNumbersLeaveScoreRoom() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 1000, height: 180))
        view.update(entries: entries, selectionIndex: 0, numbers: [0: "1"], documentWidths: [810, 40])
        openTree(in: view)
        XCTAssertGreaterThan(view.preferredSize.width, 830)
        let controls = buttons(in: view)
        let word = try XCTUnwrap(controls.first { $0.title == "語" })
        let number = try XCTUnwrap(controls.first { $0.title == "1" })
        XCTAssertGreaterThanOrEqual(number.frame.minY, word.frame.maxY + 12,
                                    "The shortcut number must leave the score line unobstructed")
    }

    func testNarrowDocumentColumnsLeaveNumberTargetsSeparate() throws {
        let preference = Config.CandidateTextSize()
        let previous = preference.value
        defer { preference.value = previous }
        for size in [Config.CandidateTextSize.Value.standard, .large] {
            preference.value = size
            let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
            let width = CGFloat(size.pointSize) + 8
            view.update(entries: [
                .init(text: "日", tokens: [.init(text: "日")], candidateIndex: 0),
                .init(text: "日本", tokens: [.init(text: "日"), .init(text: "本")], candidateIndex: 1)
            ], selectionIndex: 1, numbers: [0: "1", 1: "2"], documentWidths: [width, width])
            openTree(in: view)
            view.layoutSubtreeIfNeeded()
            let first = try XCTUnwrap(buttons(in: view).first { $0.title == "1" })
            let second = try XCTUnwrap(buttons(in: view).first { $0.title == "2" })
            XCTAssertLessThanOrEqual(first.frame.maxX, second.frame.minX)
            XCTAssertGreaterThanOrEqual(first.frame.height, CGFloat(size.pointSize) + 14)
        }
    }

    func testDocumentGeometryUsesUTF16OffsetsAndRejectsWrappedText() throws {
        var queries: [Int] = []
        let geometry = try XCTUnwrap(CandidateDocumentGeometry(words: ["🙂", "日本", "日本"], preedit: "🙂日本日本") { offset in
            queries.append(offset)
            return NSRect(x: 100 + offset * 10, y: 200, width: 1, height: 20)
        })
        XCTAssertEqual(queries, [0, 2, 4, 6])
        XCTAssertEqual(geometry.widths, [20, 20, 20])
        XCTAssertEqual(geometry.anchor.x + 12, 100)
        XCTAssertNil(CandidateDocumentGeometry(words: ["日本", "語"], preedit: "日本語") { offset in
            NSRect(x: offset * 10, y: offset > 1 ? 180 : 200, width: 1, height: 20)
        })
        XCTAssertNil(CandidateDocumentGeometry(words: ["日本"], preedit: "にほん") { _ in
            XCTFail("Do not query unrelated candidate text")
            return .zero
        })
    }

    func testDocumentAlignmentFallsBackWhenTheDetailWidthCrossesTheScreenEdge() throws {
        let geometry = try XCTUnwrap(CandidateDocumentGeometry(words: ["語"], preedit: "語") { offset in
            NSRect(x: 600 + offset * 32, y: 200, width: 1, height: 24)
        })
        XCTAssertFalse(geometry.fits(in: CGRect(x: 0, y: 0, width: 800, height: 600)))
        XCTAssertTrue(geometry.fits(in: CGRect(x: 0, y: 0, width: 1200, height: 600)))
        let secondScreen = try XCTUnwrap(CandidateDocumentGeometry(words: ["語"], preedit: "語") { offset in
            NSRect(x: -600 + offset * 32, y: 200, width: 1, height: 24)
        })
        XCTAssertTrue(secondScreen.fits(in: CGRect(x: -800, y: 0, width: 800, height: 600)))
    }

    func testDefaultLayoutShowsCompleteCandidatesBeforeOptionalSegmentsAndDetails() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        let alternatives = (0..<100).map {
            CandidateTree.Entry(text: "日本語候補\($0)", tokens: [.init(text: "日本語"), .init(text: "候補\($0)")], candidateIndex: $0)
        }
        view.update(entries: alternatives, selectionIndex: 0)
        let visible = buttons(in: view)
        XCTAssertLessThanOrEqual(view.preferredSize.height, 600, "The primary list remains bounded")
        XCTAssertEqual(view.preferredSize.width, CandidateDetailView.minimumWidth)
        XCTAssertLessThanOrEqual(visible.count, CandidatePage.size + 5)
        XCTAssertTrue(visible.contains { $0.title == "日本語候補0" })
        XCTAssertTrue(visible.contains { $0.title == Localization.text("candidate.openTree") })
        XCTAssertTrue(visible.contains { $0.title == Localization.text("candidate.openDetails") })
        XCTAssertTrue(candidateButtons(in: view).isEmpty, "Segments are disclosed only when needed")
    }

    func testRedrawDoesNotNotifyAndNavigationNotifiesOnce() {
        let view = CandidateTreeView()
        var selections: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        XCTAssertEqual(selections, [])
        XCTAssertTrue(view.navigate(.right))
        XCTAssertTrue(view.navigate(.down))
        XCTAssertEqual(selections, [1])
        view.update(entries: entries, selectionIndex: 1)
        XCTAssertEqual(selections, [1])
    }

    func testAccessibleSelectionChangesWithoutTakingKeyboardFocus() throws {
        let view = CandidateTreeView()
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        let original = try XCTUnwrap(buttons(in: view).first { $0.title == "語" })
        XCTAssertTrue(original.isAccessibilitySelected())
        XCTAssertFalse(original.acceptsFirstResponder)
        XCTAssertTrue(view.navigate(.right))
        XCTAssertTrue(view.navigate(.down))
        let alternative = try XCTUnwrap(buttons(in: view).first { $0.title == "画" })
        XCTAssertTrue(alternative.isAccessibilitySelected())
        XCTAssertFalse(original.isAccessibilitySelected())
    }

    func testStaleAndEmptyCandidatesCannotBeSubmitted() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        view.update(entries: [], selectionIndex: nil)
        view.submit(candidateIndex: 0)
        XCTAssertEqual(submitted, [])
        XCTAssertFalse(view.navigate(.down))
    }

    func testOldAccessibleActionCannotSelectNewCandidateWithSameNodeID() throws {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        var selected: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.onSelectionChanged = { selected.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        let oldButton = try XCTUnwrap(buttons(in: view).first { $0.title == "日本" })
        view.update(entries: [.init(text: "日本に帰る", tokens: [.init(text: "日本"), .init(text: "に帰る")],
                                    candidateIndex: 0)], selectionIndex: 0)
        oldButton.performClick(nil)
        XCTAssertEqual(submitted, [])
        XCTAssertEqual(selected, [])
        buttons(in: view).first { $0.title == "日本" }?.performClick(nil)
        XCTAssertEqual(submitted, [])
        XCTAssertEqual(selected, [0])
        confirm(in: view)
        XCTAssertEqual(submitted, [0])
    }

    func testTerminalClickChoosesExactCandidateIncludingDuplicateText() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: [
            .init(text: "同じ", tokens: [], candidateIndex: 0),
            .init(text: "同じ", tokens: [], candidateIndex: 1)
        ], selectionIndex: 0)
        openTree(in: view)
        view.submit(candidateIndex: 1)
        XCTAssertEqual(submitted, [1])
    }

    func testNumberPageChangeKeepsControlsAndSubmitsCurrentCandidate() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 0, numbers: [0: "1", 1: "2"])
        openTree(in: view)
        let originalButtons = candidateButtons(in: view)

        view.update(entries: entries, selectionIndex: 1, numbers: [0: "9", 1: "1"])

        let updatedButtons = candidateButtons(in: view)
        XCTAssertEqual(Set(originalButtons.map(ObjectIdentifier.init)), Set(updatedButtons.map(ObjectIdentifier.init)),
                       "Changing number labels must retain existing tree controls, avoiding a full layout rebuild")
        XCTAssertTrue(updatedButtons.contains { $0.title == "9" })
        XCTAssertEqual(submitted, [])
        updatedButtons.first { $0.title == "9" }?.performClick(nil)
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        XCTAssertEqual(submitted, [0], "The retained button still selects its original converter index")
    }

    func testLargeTreeKeepsAlternativesCompactAndSelectionKeepsCandidateIndex() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        let many = (0..<500).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: many, selectionIndex: 0, numbers: [499: "9"])
        openTree(in: view)
        XCTAssertLessThan(buttons(in: view).count, 40, "Offscreen candidates must not allocate hundreds of AppKit controls")

        view.update(entries: many, selectionIndex: 499, numbers: [499: "9"])
        XCTAssertLessThan(buttons(in: view).count, 40)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "候補499" })
        XCTAssertEqual(submitted, [])
        buttons(in: view).first { $0.title == "9" }?.performClick(nil)
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        XCTAssertEqual(submitted, [499])

        view.update(entries: many, selectionIndex: 0)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "候補0" }, "Keyboard selection must reveal previously offscreen nodes")
    }

    func testNewCandidatesRefreshReusedNodeTitles() {
        let view = CandidateTreeView()
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        view.update(entries: [.init(text: "更新", tokens: [], candidateIndex: 0)], selectionIndex: 0)
        XCTAssertEqual(candidateButtons(in: view).map(\.title), ["更新"])
        XCTAssertEqual(view.subviews.compactMap { $0 as? CandidateNavigationView }.count, 1)
    }

    func testChangingAppearancePreservesCandidateActionsAndNeverSubmitsText() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        let original = Set(buttons(in: view).map(ObjectIdentifier.init))
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(Set(buttons(in: view).map(ObjectIdentifier.init)), original)
            XCTAssertFalse(buttons(in: view).contains { $0.acceptsFirstResponder })
            XCTAssertEqual(submitted, [])
        }
        buttons(in: view).first { $0.title == "画" }?.performClick(nil)
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        XCTAssertEqual(submitted, [1])
    }

    func testDuplicateCandidateNumbersDoNotOverlap() {
        let view = CandidateTreeView()
        view.update(entries: [
            .init(text: "同じ", tokens: [], candidateIndex: 0),
            .init(text: "同じ", tokens: [], candidateIndex: 1)
        ], selectionIndex: 1, numbers: [0: "1", 1: "2"])
        openTree(in: view)
        XCTAssertEqual(candidateButtons(in: view).map(\.title).sorted(), ["2", "同じ"])
        XCTAssertEqual(view.subviews.compactMap { $0 as? CandidateNavigationView }.count, 1)
    }

    func testAlternativeClickSelectsItsRealCandidateBeforeExplicitCommit() {
        let view = CandidateTreeView()
        var committed: [Int] = []
        view.onCandidateSubmitted = { committed.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        buttons(in: view).first { $0.title == "画" }?.performClick(nil)
        XCTAssertEqual(committed, [])
        confirm(in: view)
        XCTAssertEqual(committed, [1])
    }

    func testReferenceRenderingHasOpaquePanelWithTransparentCorners() throws {
        let view = CandidateTreeView()
        let tokens = ["このように", "確率的に", "候補", "がある", "中を", "AI", "に", "よ"]
        var fixture = [CandidateTree.Entry(text: tokens.joined(), tokens: tokens.map { .init(text: $0) }, candidateIndex: 0)]
        for (depth, words) in [0: ["この世", "来"], 4: ["仲を", "なかを"], 5: ["ＡＩ"], 6: ["二", "ニ"], 7: ["良", "世"]] {
            for word in words {
                var path = tokens
                path[depth] = word
                fixture.append(.init(text: path.joined(), tokens: path.map { .init(text: $0) }, candidateIndex: fixture.count))
            }
        }
        view.update(entries: fixture, selectionIndex: 0)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        for (name, appearance) in [
            ("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
            ("highContrastLight", .accessibilityHighContrastAqua), ("highContrastDark", .accessibilityHighContrastDarkAqua)
        ] {
            view.appearance = NSAppearance(named: appearance)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertEqual(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)?.alphaComponent, 0)
            XCTAssertEqual(bitmap.colorAt(x: 10, y: 10)?.alphaComponent, 1,
                           "The document behind the candidate region must not show through")
            if let directory = ProcessInfo.processInfo.environment["AZOOKEY_TREE_SNAPSHOT_DIR"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("macos-compact-\(name).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    func testKeyboardNavigationRevealsOffscreenChildAndTerminal() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        let tokens = (0..<20).map { CandidateTree.Token(text: "文節\($0)") }
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: [.init(text: tokens.map(\.text).joined(), tokens: tokens, candidateIndex: 42)],
                    selectionIndex: 42, numbers: [42: "7"])
        openTree(in: view)
        XCTAssertFalse(buttons(in: view).contains { $0.title == "文節19" })
        for _ in 0..<19 { XCTAssertTrue(view.navigate(.right)) }
        XCTAssertTrue(buttons(in: view).contains { $0.title == "文節19" })
        let terminal = buttons(in: view).first { $0.title == "7" }
        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
        XCTAssertNotNil(terminal)
        XCTAssertTrue(terminal.map { scroll.documentVisibleRect.contains($0.frame) } ?? false,
                      "The terminal number must be fully visible, not clipped at the right edge")
        terminal?.performClick(nil)
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        XCTAssertEqual(submitted, [42])
        for _ in 0..<19 { XCTAssertTrue(view.navigate(.left)) }
        XCTAssertTrue(buttons(in: view).contains { $0.title == "文節0" })
    }

    func testSelectingACompleteRowUpdatesTheCommitTextButHoverDoesNot() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 480, height: 500))
        var selected: [Int] = []
        var submitted: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: partialEntries, selectionIndex: 0, numbers: [0: "1", 1: "2", 2: "3"])
        let composition = try XCTUnwrap(view.subviews.compactMap { $0 as? CandidateCompositionView }.first)
        XCTAssertTrue(textFields(in: composition).contains { $0.stringValue == "日本語" })
        XCTAssertTrue(textFields(in: composition).contains { $0.stringValue.contains("残る読み: にゅうりょく") })
        XCTAssertFalse(composition.subviews.contains { $0.isHidden })
        let full = try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }
            .first { $0.candidateIndex == 1 })
        full.mouseEntered(with: try hoverEvent(.mouseEntered))
        XCTAssertTrue(textFields(in: composition).contains { $0.stringValue == "日本語" })
        XCTAssertTrue(detailText(in: view).contains("全文の注釈"))
        XCTAssertEqual(selected, [])
        XCTAssertEqual(submitted, [])
        full.performClick(nil)
        XCTAssertEqual(selected, [1])
        XCTAssertTrue(textFields(in: composition).contains { $0.stringValue == "日本語入力" })
        XCTAssertTrue(composition.subviews.contains { $0.isHidden }, "The empty remaining-reading area is hidden")
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        XCTAssertEqual(submitted, [1])
    }

    func testConfirmRetiresBeforeCallingBackAndOldSelectionCannotAcquireANewTarget() throws {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        let oldConfirm = try XCTUnwrap(buttons(in: view).first {
            $0.accessibilityLabel() == Localization.text("candidate.submit")
        })
        try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }
            .first { $0.candidateIndex == 1 }).performClick(nil)
        oldConfirm.performClick(nil)
        XCTAssertEqual(submitted, [])
        let current = try XCTUnwrap(buttons(in: view).first {
            $0.accessibilityLabel() == Localization.text("candidate.submit")
        })
        current.performClick(nil)
        current.performClick(nil)
        XCTAssertEqual(submitted, [1])
        XCTAssertFalse(current.isEnabled)
        XCTAssertFalse(buttons(in: view).contains { $0.acceptsFirstResponder })
    }

    func testReplacingTheTextAtTheSameIndexInvalidatesRetainedConfirmActions() throws {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { index in
            submitted.append(index)
            view.update(entries: [], selectionIndex: nil)
        }
        view.update(entries: [.init(text: "前の候補", tokens: [], candidateIndex: 7)], selectionIndex: 7)
        let oldConfirm = try XCTUnwrap(buttons(in: view).first {
            $0.accessibilityLabel() == Localization.text("candidate.submit")
        })
        view.update(entries: [.init(text: "新しい候補", tokens: [], candidateIndex: 7)], selectionIndex: 7)
        oldConfirm.performClick(nil)
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        confirm(in: view)
        oldConfirm.performClick(nil)
        XCTAssertEqual(submitted, [7])
    }

    func testDefaultArrowNavigationSelectsCompleteCandidatesWithTheirOriginalIndices() throws {
        let view = CandidateTreeView()
        let entries: [CandidateTree.Entry] = [
            .init(text: "日本語", tokens: [.init(text: "日本"), .init(text: "語")], candidateIndex: 7),
            .init(text: "日本画", tokens: [.init(text: "日本"), .init(text: "画")], candidateIndex: 42)
        ]
        var selected: [Int] = []
        var submitted: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 7)
        XCTAssertTrue(view.navigate(.down))
        XCTAssertEqual(selected, [42])
        XCTAssertTrue(try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }
            .first { $0.candidateIndex == 42 }).isAccessibilitySelected())
        XCTAssertTrue(view.navigate(.up))
        XCTAssertEqual(selected, [42, 7])
        XCTAssertTrue(candidateButtons(in: view).isEmpty)
        XCTAssertTrue(view.navigate(.right))
        XCTAssertFalse(candidateButtons(in: view).isEmpty)
        XCTAssertEqual(submitted, [])
    }

    func testChoosingTheAlreadyHighlightedRowStillNotifiesTheInputState() throws {
        let view = CandidateTreeView()
        var selected: [Int] = []
        var submitted: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: nil)
        let initialConfirm = try XCTUnwrap(buttons(in: view).first {
            $0.accessibilityLabel() == Localization.text("candidate.submit")
        })
        XCTAssertFalse(initialConfirm.isEnabled)
        XCTAssertTrue(view.navigate(.down))
        XCTAssertEqual(selected, [0], "Down starts at the first real candidate when none was selected")
        try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }
            .first { $0.candidateIndex == 0 }).performClick(nil)
        XCTAssertEqual(selected, [0, 0], "A pointer selection enters selecting mode even when the index is unchanged")
        XCTAssertEqual(submitted, [])
        confirm(in: view)
        XCTAssertEqual(submitted, [0])
    }

    func testClosingSegmentsInvalidatesTheirHoverAndSelectionActions() throws {
        let view = CandidateTreeView()
        var selected: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        openTree(in: view)
        let oldAlternative = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "画" })
        oldAlternative.mouseEntered(with: try hoverEvent(.mouseEntered))
        XCTAssertTrue(detailText(in: view).contains("確定予定: 日本画"))
        try XCTUnwrap(buttons(in: view).first { $0.title == Localization.text("candidate.closeTree") }).performClick(nil)
        oldAlternative.mouseEntered(with: try hoverEvent(.mouseEntered))
        oldAlternative.mouseExited(with: try hoverEvent(.mouseExited))
        oldAlternative.performClick(nil)
        XCTAssertTrue(detailText(in: view).contains("確定予定: 日本語"))
        XCTAssertEqual(selected, [])
        XCTAssertTrue(candidateButtons(in: view).isEmpty)
    }

    func testLongPartialCommitKeepsTheRemainingReadingOutsideTheScrollableText() throws {
        let view = CandidateTreeView()
        let text = String(repeating: "長い文章👩‍💻", count: 60)
        let entry = CandidateTree.Entry(text: text, tokens: [], candidateIndex: 0,
                                       scope: .init(consumedReading: "ながい", remainingReading: "つづき"))
        view.update(entries: [entry], selectionIndex: 0)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let composition = try XCTUnwrap(view.subviews.compactMap { $0 as? CandidateCompositionView }.first)
        let areas = composition.subviews.compactMap { $0 as? CandidateDetailView }
        let commitArea = try XCTUnwrap(areas.first { textFields(in: $0).contains { $0.stringValue == text } })
        let readingArea = try XCTUnwrap(areas.first { textFields(in: $0).contains { $0.stringValue.contains("残る読み: つづき") } })
        XCTAssertGreaterThan(readingArea.frame.height, 0)
        XCTAssertLessThanOrEqual(readingArea.frame.maxY, commitArea.frame.minY)
        let readingFrame = readingArea.frame
        XCTAssertTrue(view.scrollDetails(forward: true))
        XCTAssertGreaterThan(commitArea.contentView.bounds.minY, 0)
        XCTAssertEqual(readingArea.frame, readingFrame)
        XCTAssertEqual(readingArea.contentView.bounds.minY, 0)
        let displayed = try XCTUnwrap(textFields(in: commitArea).first).stringValue
        XCTAssertEqual(Array(displayed.utf8), Array(text.utf8))
    }

    func testDetailsScrollWithoutMovingTheSelectedCommitTextOrTakingFocus() throws {
        let view = CandidateTreeView()
        view.update(entries: [.init(text: "候補", tokens: [], candidateIndex: 0,
                                    annotation: String(repeating: "長い注釈です。", count: 100))], selectionIndex: 0)
        try XCTUnwrap(buttons(in: view).first { $0.title == Localization.text("candidate.openDetails") }).performClick(nil)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let details = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier() == "candidate-details" } as? CandidateDetailView)
        let composition = try XCTUnwrap(view.subviews.compactMap { $0 as? CandidateCompositionView }.first)
        let before = textFields(in: composition).map(\.stringValue)
        XCTAssertTrue(view.scrollDetails(forward: true))
        XCTAssertGreaterThan(details.contentView.bounds.minY, 0)
        XCTAssertEqual(textFields(in: composition).map(\.stringValue), before)
        XCTAssertFalse(buttons(in: view).contains { $0.acceptsFirstResponder })
        let panel = CandidateTreePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: true)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
}
