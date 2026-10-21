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
        XCTAssertTrue(try side(in: view).isHidden)
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        XCTAssertEqual(fixture.words, ["橋"])
        XCTAssertTrue(try side(in: view).isHidden)
        fixture.completions[0]("橋の意味")
        XCTAssertFalse(try side(in: view).isHidden)
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
        let row = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateRowButton }.first { $0.candidateIndex == 7 })
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
        let oldRow = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateRowButton }.first)
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

    func testFullDefinitionMovesToTheRightWhileCandidateMetadataStaysSeparate() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        let full = "語の説明\n合成した用例。\n" + String(repeating: "長い説明。", count: 100)
        fixture.completions[0](full)
        let side = try side(in: view)
        let toggle = try XCTUnwrap(candidateViewDescendants(in: side).compactMap { $0 as? CandidatePresentationButton }.first)
        toggle.activate?()
        let fullText = candidateViewDescendants(in: side).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n")
        XCTAssertTrue(fullText.contains(full))
        XCTAssertTrue(fullText.contains(Localization.text("candidate.definition.source")))
        XCTAssertTrue(fullText.contains(Localization.text("candidate.definition.readingNote")))
        let details = try XCTUnwrap(candidateViewDescendants(in: view).first { $0.accessibilityIdentifier() == "candidate-details" } as? CandidateDetailView)
        let text = try XCTUnwrap(candidateViewDescendants(in: details).compactMap { $0 as? NSTextField }.first).stringValue
        XCTAssertFalse(text.contains(full))
        XCTAssertFalse(side.acceptsFirstResponder)
    }

    func testNarrowViewportReachesTheRightColumnWithoutSelectingOrSubmittingACandidate() throws {
        for width: CGFloat in [1000, 640, 320] {
            let fixture = Fixture()
            let view = fixture.view()
            var selections: [Int] = []
            var submissions: [Int] = []
            view.onSelectionChanged = { selections.append($0) }
            view.onCandidateSubmitted = { submissions.append($0) }
            view.setAvailableWidth(width)
            view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
            fixture.completions[0](String(repeating: "長い現在の語の説明。", count: 100))
            view.frame = NSRect(origin: .zero, size: view.preferredSize)
            view.layoutSubtreeIfNeeded()
            let side = try side(in: view)
            let navigation = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateNavigationView }.first)
            let viewport = try XCTUnwrap(candidateViewDescendants(in: view).first { $0.accessibilityIdentifier() == "candidate-side-viewport" } as? NSScrollView)
            XCTAssertGreaterThan(side.frame.minX, navigation.frame.maxX)
            XCTAssertEqual(side.frame.maxY, navigation.frame.maxY)
            XCTAssertLessThanOrEqual(view.frame.width, width)
            let maximumOffset = max(0, try XCTUnwrap(viewport.documentView).frame.width - viewport.contentSize.width)
            viewport.contentView.scroll(to: NSPoint(x: maximumOffset, y: 0))
            viewport.reflectScrolledClipView(viewport.contentView)
            XCTAssertTrue(viewport.contentView.bounds.intersects(side.frame))
            if width < 550 {
                XCTAssertTrue(viewport.hasHorizontalScroller)
                XCTAssertGreaterThan(maximumOffset, 0)
            }
            let toggle = try XCTUnwrap(candidateViewDescendants(in: side).compactMap { $0 as? CandidatePresentationButton }.first)
            toggle.activate?()
            XCTAssertTrue(side.expanded)
            XCTAssertEqual(fixture.model.target?.candidateIndex, 42)
            XCTAssertTrue(selections.isEmpty)
            XCTAssertTrue(submissions.isEmpty)
        }
    }

    func testOpeningTheFullDefinitionUsesTheTallerColumnInsteadOfAddingBelowTheCandidates() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.setAvailableWidth(1000)
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        fixture.completions[0](String(repeating: "長い語の説明。", count: 100))
        let side = try side(in: view)
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let navigation = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateNavigationView }.first)
        let rows = candidateViewDescendants(in: navigation).compactMap { $0 as? CandidateRowButton }
        let candidateSize = navigation.frame.size
        let rowSizes = rows.map(\.frame.size)
        let toggle = try XCTUnwrap(candidateViewDescendants(in: side).compactMap { $0 as? CandidatePresentationButton }.first)
        toggle.activate?()
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let composition = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateCompositionView }.first)
        let actions = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateActionsView }.first)
        let leftHeight = navigation.preferredHeight(width: navigation.frame.width) + actions.preferredHeight(width: navigation.frame.width)
        XCTAssertTrue(composition.isHidden)
        XCTAssertEqual(view.preferredSize.height, max(leftHeight, side.preferredHeight))
        XCTAssertEqual(navigation.frame.size, candidateSize)
        XCTAssertEqual(rows.map(\.frame.size), rowSizes)
        XCTAssertEqual(rows.count, 2)
        XCTAssertGreaterThanOrEqual(side.frame.height, 280)
        XCTAssertLessThanOrEqual(side.frame.height, 340)
        XCTAssertEqual(side.frame.maxY, navigation.frame.maxY)
    }

    func testTheDefaultMenuUsesSevenDenseRowsAndAFlatFooterWithoutTheLargeCompositionOrHint() throws {
        let preference = Config.CandidateTextSize()
        let rowPreference = Config.CandidateVisibleRows()
        let previous = preference.value
        let previousRows = rowPreference.value
        defer {
            preference.value = previous
            rowPreference.value = previousRows
        }
        rowPreference.value = .seven
        let fixture = Fixture()
        let view = fixture.view()
        let entries = (0..<20).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        for size in [Config.CandidateTextSize.Value.standard, .large] {
            preference.value = size
            view.update(entries: entries, selectionIndex: 0, enterConfirmsCandidate: true)
            view.frame = NSRect(origin: .zero, size: view.preferredSize)
            view.layoutSubtreeIfNeeded()
            let navigation = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateNavigationView }.first)
            let rowScroll = try XCTUnwrap(navigation.subviews.compactMap { $0 as? NSScrollView }.first)
            let rows = candidateViewDescendants(in: navigation).compactMap { $0 as? CandidateRowButton }
            XCTAssertEqual(rows.count, 9, "Every real number-key candidate stays reachable by scrolling")
            XCTAssertEqual(rowScroll.contentSize.height, rows[0].frame.height * 7, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(rows[0].frame.height, 32)
            XCTAssertEqual(rows[0].font?.pointSize, CGFloat(size.pointSize))
            XCTAssertTrue(navigation.subviews.compactMap { $0 as? NSTextField }.allSatisfy(\.isHidden))
            XCTAssertTrue(try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateCompositionView }.first).isHidden)
            let footer = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateActionsView }.first)
            let controls = footer.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            XCTAssertEqual(controls.count, 4)
            XCTAssertEqual(footer.frame.height, 32)
            XCTAssertTrue(controls.allSatisfy { $0.frame.height == 28 && !$0.acceptsFirstResponder })
            XCTAssertTrue(controls.compactMap { $0 as? CandidatePresentationButton }.allSatisfy(\.isFlat))
            XCTAssertEqual(navigation.frame.width, 260 * CGFloat(size.pointSize) / 18, accuracy: 0.01)
        }
    }

    func testCompactFooterPagesUseRealIndicesAndRetireOldActionsBeforeConfirmation() throws {
        let fixture = Fixture()
        let view = fixture.view()
        let entries = (0..<20).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0 + 40) }
        var selected: [Int] = []
        var submitted: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 40, enterConfirmsCandidate: true)
        let next = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidatePresentationButton }
            .first { $0.accessibilityIdentifier() == "candidate.nextPage" })
        let oldAction = try XCTUnwrap(next.activate)
        XCTAssertEqual(next.accessibilityHelp(), String(format: Localization.text("candidate.position"), "1", "20"))
        next.performClick(nil)
        XCTAssertEqual(selected, [49])
        withExtendedLifetime(next) { oldAction() }
        XCTAssertEqual(selected, [49])
        let confirm = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidatePresentationButton }
            .first { $0.accessibilityIdentifier() == "candidate-confirm" })
        XCTAssertEqual(confirm.title, Localization.text("candidate.submit") + "  ↵")
        XCTAssertEqual(confirm.accessibilityHelp(), String(format: Localization.text("candidate.position"), "10", "20"))
        let retiredConfirmAction = try XCTUnwrap(confirm.activate)
        confirm.performClick(nil)
        confirm.performClick(nil)
        withExtendedLifetime(confirm) { retiredConfirmAction() }
        XCTAssertEqual(submitted, [49])
    }

    func testMovingFromAHoveredWordIntoItsDefinitionKeepsTheTargetUntilThePointerOrSelectionLeaves() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.setAvailableWidth(1000)
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        _ = view.navigate(.right)
        XCTAssertEqual(fixture.model.target?.word, "を渡る")
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateRowButton }.first { $0.candidateIndex == 7 })
        row.preview?(true)
        fixture.completions.last?("橋の現在の説明")
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let side = try side(in: view)
        fixture.pointerPoint = side.convert(NSPoint(x: 20, y: 20), to: view)
        row.preview?(false)
        XCTAssertEqual(fixture.model.target?.candidateIndex, 7)
        let oldCompletion = try XCTUnwrap(fixture.completions.last)
        oldCompletion("橋の現在の説明")
        XCTAssertEqual(fixture.model.result, .definition("橋の現在の説明"))
        fixture.pointerPoint = NSPoint(x: -10, y: -10)
        side.onPointerExit?()
        XCTAssertEqual(fixture.model.target?.word, "を渡る")
        row.preview?(true)
        fixture.completions.last?("橋の現在の説明")
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        fixture.pointerPoint = side.convert(NSPoint(x: 20, y: 20), to: view)
        row.preview?(false)
        let retiredCompletion = try XCTUnwrap(fixture.completions.last)
        _ = view.navigate(.left)
        retiredCompletion("退役したhoverの説明")
        XCTAssertEqual(fixture.model.target?.candidateIndex, 42)
        XCTAssertEqual(fixture.model.result, .loading)
    }

    func testClosingTheTreeRetiresTheDefinitionRetainedFromAnOldControl() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.setAvailableWidth(1000)
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        _ = view.navigate(.right)
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateRowButton }.first { $0.candidateIndex == 7 })
        row.preview?(true)
        fixture.completions.last?("橋の現在の説明")
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let side = try side(in: view)
        fixture.pointerPoint = side.convert(NSPoint(x: 20, y: 20), to: view)
        row.preview?(false)
        let oldCompletion = try XCTUnwrap(fixture.completions.last)
        XCTAssertEqual(fixture.model.target?.candidateIndex, 7)
        let closeTree = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidatePresentationButton }
            .first { $0.accessibilityIdentifier() == "candidate-tree-toggle" })
        closeTree.activate?()
        row.preview?(true)
        oldCompletion("閉じた木の古い対象")
        XCTAssertEqual(fixture.model.target?.candidateIndex, 42)
        XCTAssertEqual(fixture.model.target?.word, "を渡る")
        XCTAssertEqual(fixture.model.result, .loading)
    }

    func testShortWorkAreaKeepsLongCommitTextAndOneCandidateRowInSeparateScrollableAreas() throws {
        let fixture = Fixture()
        let view = fixture.view()
        let longText = String(repeating: "長い変換候補です。", count: 100)
        let entry = CandidateTree.Entry(text: longText, tokens: [.init(text: longText, reading: "ナガイ")], candidateIndex: 42,
                                        scope: .init(consumedReading: "ながい", remainingReading: String(repeating: "のこり", count: 100)))
        view.setAvailableWidth(640)
        view.update(entries: [entry], selectionIndex: 42, enterConfirmsCandidate: true)
        fixture.completions[0](String(repeating: "長い語釈です。", count: 100))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        view.layoutSubtreeIfNeeded()
        let composition = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateCompositionView }.first)
        let navigation = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidateNavigationView }.first)
        let side = try side(in: view)
        XCTAssertLessThanOrEqual(composition.frame.height, 112)
        XCTAssertGreaterThanOrEqual(navigation.frame.height, navigation.minimumHeight)
        XCTAssertEqual(side.frame.maxY, navigation.frame.maxY)
        XCTAssertTrue(side.subviews.allSatisfy { side.bounds.contains($0.frame) })
        let commitText = candidateViewDescendants(in: composition).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(commitText.contains(longText))
        XCTAssertFalse(side.acceptsFirstResponder)
    }

    func testUnfoundWordsRemoveTheSidebarGapAndHorizontalScrollbarAtBothTextSizes() throws {
        let preference = Config.CandidateTextSize()
        let previous = preference.value
        defer { preference.value = previous }
        for size in [Config.CandidateTextSize.Value.standard, .large] {
            preference.value = size
            let fixture = Fixture()
            let view = fixture.view()
            view.setAvailableWidth(1000)
            view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
            let expectedWidth = 260 * CGFloat(size.pointSize) / 18
            XCTAssertEqual(view.preferredSize.width, expectedWidth, accuracy: 0.01)
            fixture.completions.last?(nil)
            XCTAssertTrue(try side(in: view).isHidden)
            XCTAssertEqual(view.preferredSize.width, expectedWidth, accuracy: 0.01)
            let next = [CandidateTree.Entry(text: "語彙", tokens: [], candidateIndex: 47)]
            view.update(entries: next, selectionIndex: 47, enterConfirmsCandidate: true)
            fixture.completions.last?("言葉の集まり")
            XCTAssertFalse(try side(in: view).isHidden)
            XCTAssertGreaterThan(view.preferredSize.width, expectedWidth)
            view.update(entries: [.init(text: "未収録", tokens: [], candidateIndex: 48)], selectionIndex: 48, enterConfirmsCandidate: true)
            XCTAssertTrue(try side(in: view).isHidden)
            fixture.completions.last?(nil)
            view.frame = NSRect(origin: .zero, size: view.preferredSize)
            view.layoutSubtreeIfNeeded()
            let viewport = try XCTUnwrap(candidateViewDescendants(in: view).first {
                $0.accessibilityIdentifier() == "candidate-side-viewport"
            } as? NSScrollView)
            XCTAssertEqual(view.frame.width, expectedWidth, accuracy: 0.01)
            XCTAssertFalse(viewport.hasHorizontalScroller)
            XCTAssertEqual(viewport.documentView?.frame.width, expectedWidth)
        }
    }

    func testBackgroundAvailabilityMarksRealRowsWithoutSelectingThemAndRetiresOnHide() throws {
        let fixture = Fixture()
        let view = fixture.view()
        var selected: [Int] = []
        var submitted: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: fixture.entries, selectionIndex: 42, numbers: [7: "1", 42: "2"], enterConfirmsCandidate: true)
        let rows = candidateViewDescendants(in: view).compactMap { $0 as? CandidateRowButton }
        XCTAssertTrue(rows.allSatisfy { !$0.hasDefinition })
        XCTAssertEqual(fixture.availabilityWords, [["橋", "橋"]])
        fixture.availabilityCompletions[0]([true, false])
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.candidateIndex == 7 }).hasDefinition)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.candidateIndex == 42 }).hasDefinition)
        XCTAssertEqual(fixture.model.target?.candidateIndex, 42)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertTrue(submitted.isEmpty)
        view.setDefinitionsEnabled(false)
        fixture.availabilityCompletions[0]([true, true])
        XCTAssertTrue(rows.allSatisfy { !$0.hasDefinition })
        XCTAssertTrue(try side(in: view).isHidden)
    }

    func testMissingDefinitionsStillAllowTheIndependentTreeControlToOpenAndClose() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        fixture.completions.last?(nil)
        let segments = try XCTUnwrap(candidateViewDescendants(in: view).first { $0.accessibilityIdentifier() == "candidate-segments" })
        XCTAssertTrue(segments.isHidden)
        for expectedHidden in [false, true] {
            let toggle = try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? CandidatePresentationButton }
                .first { $0.accessibilityIdentifier() == "candidate-tree-toggle" })
            toggle.activate?()
            XCTAssertEqual(segments.isHidden, expectedHidden)
            XCTAssertTrue(try side(in: view).isHidden)
        }
    }

    func testChangingWordDepthRetiresTheOldPageAvailabilityAndChecksEachRealPath() throws {
        let fixture = Fixture()
        let view = fixture.view()
        view.update(entries: fixture.entries, selectionIndex: 42, enterConfirmsCandidate: true)
        let originalPage = try XCTUnwrap(fixture.availabilityCompletions.last)
        _ = view.navigate(.right)
        XCTAssertEqual(fixture.availabilityWords.last, ["橋", "を渡る"])
        originalPage([true, true])
        let rows = candidateViewDescendants(in: view).compactMap { $0 as? CandidateRowButton }
        XCTAssertTrue(rows.allSatisfy { !$0.hasDefinition })
        fixture.availabilityCompletions.last?([false, true])
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.candidateIndex == 7 }).hasDefinition)
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.candidateIndex == 42 }).hasDefinition)
    }

    private func side(in view: NSView) throws -> WordDefinitionsSideView {
        try XCTUnwrap(candidateViewDescendants(in: view).compactMap { $0 as? WordDefinitionsSideView }.first)
    }

    @MainActor
    private final class Fixture {
        let entries: [CandidateTree.Entry] = [
            .init(text: "橋", tokens: [.init(text: "橋", reading: "ハシ")], candidateIndex: 7),
            .init(text: "橋を渡る", tokens: [.init(text: "橋", reading: "ハシ"), .init(text: "を渡る", reading: "ヲワタル")], candidateIndex: 42)
        ]
        var words: [String] = []
        var completions: [WordDefinitionsService.Completion] = []
        var availabilityWords: [[String]] = []
        var availabilityCompletions: [WordDefinitionsService.AvailabilityCompletion] = []
        var pointerPoint: NSPoint?
        lazy var availability = WordDefinitionsAvailabilityModel(check: { [weak self] words, completion in
            self?.availabilityWords.append(words)
            self?.availabilityCompletions.append(completion)
        }, cancel: {})
        lazy var model = WordDefinitionsModel(search: { [weak self] in
            self?.words.append($0)
            self?.completions.append($1)
        }, cancelPending: {}, availability: availability)

        func view() -> CandidateTreeView {
            CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 500, height: 600), definitions: model,
                              pointerLocation: { [weak self] _ in self?.pointerPoint })
        }
    }
}
