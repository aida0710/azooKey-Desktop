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

    private func updateLiveTree(_ view: CandidateTreeView, entries: [CandidateTree.Entry], selectionIndex: Int?,
                            numbers: [Int: String] = [:], documentWidths: [CGFloat]? = nil) {
        view.update(entries: entries, selectionIndex: selectionIndex, numbers: numbers,
                    documentWidths: documentWidths, enterConfirmsCandidate: false)
    }

    private func openTree(in view: CandidateTreeView, file: StaticString = #filePath, line: UInt = #line) {
        // The live tree already includes alternatives; Right enters word navigation.
        _ = view.navigate(.right)
        _ = view.navigate(.left)
    }

    func testScoresExplainRelativeMeaningAndRefreshOnCandidateChange() throws {
        let preference = Config.ShowRelativeScores()
        let previous = preference.value
        defer { preference.value = previous }
        preference.value = true
        let view = CandidateTreeView()
        let scored: [CandidateTree.Entry] = [
            .init(text: "選択", tokens: [.init(text: "選択", reading: "センタク")], candidateIndex: 0, score: log(69)),
            .init(text: "洗濯", tokens: [.init(text: "洗濯", reading: "センタク")], candidateIndex: 1, score: log(31))
        ]
        updateLiveTree(view, entries: scored, selectionIndex: 0)
        openTree(in: view)
        let selection = try XCTUnwrap(buttons(in: view).first { $0.title == "選択" })
        let scoreLabel = String(format: Localization.text("candidate.score.value"), 69)
        XCTAssertTrue(selection.toolTip?.contains(scoreLabel) == true)
        XCTAssertEqual(selection.accessibilityLabel(), "選択（センタク）")
        XCTAssertTrue(selection.accessibilityHelp()?.contains(Localization.text("candidate.score.explanation")) == true)
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        XCTAssertFalse(buttons(in: view).contains { $0.toolTip?.contains(scoreLabel) == true })
    }

    func testHidingScoresKeepsTheFocusedWordAndShrinksTheTree() throws {
        let preference = Config.ShowRelativeScores()
        let previous = preference.value
        defer { preference.value = previous }
        preference.value = true
        let view = CandidateTreeView()
        // Relative scores compare candidates of the same reading, so the words carry one.
        let entries: [CandidateTree.Entry] = [
            .init(text: "選択", tokens: [.init(text: "選択", reading: "センタク")], candidateIndex: 0, score: log(69)),
            .init(text: "洗濯", tokens: [.init(text: "洗濯", reading: "センタク")], candidateIndex: 1, score: log(31))
        ]
        var selections: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        let word = try XCTUnwrap(candidateButtons(in: view).first { $0.title == "選択" })
        let height = view.preferredSize.height
        XCTAssertTrue(word.accessibilityHelp()?.contains(CandidateScorePresentation.explanation) == true)
        preference.value = false
        view.update(entries: entries, selectionIndex: 0)
        XCTAssertTrue(candidateButtons(in: view).contains { $0 === word })
        XCTAssertTrue(word.isAccessibilitySelected())
        XCTAssertFalse(word.accessibilityHelp()?.contains(CandidateScorePresentation.explanation) == true)
        XCTAssertLessThan(view.preferredSize.height, height)
        XCTAssertTrue(selections.isEmpty)
    }

    func testDocumentAlignmentReservesOnlyTheCompactTreeWidthAtScreenEdges() throws {
        let geometry = try XCTUnwrap(CandidateDocumentGeometry(words: ["語"], preedit: "語") { offset in
            NSRect(x: 760 + offset * 32, y: 200, width: 1, height: 24)
        })
        XCTAssertFalse(geometry.fits(in: CGRect(x: 0, y: 0, width: 800, height: 600)))
        XCTAssertTrue(geometry.fits(in: CGRect(x: 0, y: 0, width: 900, height: 600)))
        let secondScreen = try XCTUnwrap(CandidateDocumentGeometry(words: ["語"], preedit: "語") { offset in
            NSRect(x: -600 + offset * 32, y: 200, width: 1, height: 24)
        })
        XCTAssertTrue(secondScreen.fits(in: CGRect(x: -800, y: 0, width: 800, height: 600)))
    }

    func testLongAlternativeDoesNotMoveFollowingWords() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        openTree(in: view)
        let before = try XCTUnwrap(buttons(in: view).first { $0.title == "語" }).frame.minX
        updateLiveTree(view, entries: entries + [
            .init(text: "にほんごにゅうりょく", tokens: [], candidateIndex: 2)
        ], selectionIndex: 0)
        let after = try XCTUnwrap(buttons(in: view).first { $0.title == "語" }).frame.minX
        XCTAssertEqual(after, before, "A whole-sentence alternative must not widen the first word's column")
    }

    func testDocumentWidthsKeepEveryBranchInItsWordColumn() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        updateLiveTree(view, entries: entries, selectionIndex: 0, documentWidths: [64, 40])
        openTree(in: view)
        let controls = buttons(in: view)
        let first = try XCTUnwrap(controls.first { $0.title == "日本" })
        let chosen = try XCTUnwrap(controls.first { $0.title == "語" })
        let alternative = try XCTUnwrap(controls.first { $0.title == "画" })
        XCTAssertEqual(chosen.frame.minX - first.frame.minX, 64)
        XCTAssertEqual(alternative.frame.minX, chosen.frame.minX)
        XCTAssertEqual(alternative.frame.width, 40)
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

    func testRedrawDoesNotNotifyAndNavigationNotifiesOnce() {
        let view = CandidateTreeView()
        var selections: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        openTree(in: view)
        XCTAssertEqual(selections, [])
        XCTAssertTrue(view.navigate(.right))
        XCTAssertTrue(view.navigate(.down))
        XCTAssertEqual(selections, [1])
        updateLiveTree(view, entries: entries, selectionIndex: 1)
        XCTAssertEqual(selections, [1])
    }

    func testAccessibleSelectionChangesWithoutTakingKeyboardFocus() throws {
        let view = CandidateTreeView()
        updateLiveTree(view, entries: entries, selectionIndex: 0)
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
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        openTree(in: view)
        updateLiveTree(view, entries: [], selectionIndex: nil)
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
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        openTree(in: view)
        let oldButton = try XCTUnwrap(buttons(in: view).first { $0.title == "日本" })
        updateLiveTree(view, entries: [.init(text: "日本に帰る", tokens: [.init(text: "日本"), .init(text: "に帰る")],
                                    candidateIndex: 0)], selectionIndex: 0)
        oldButton.performClick(nil)
        XCTAssertEqual(submitted, [])
        XCTAssertEqual(selected, [])
        buttons(in: view).first { $0.title == "日本" }?.performClick(nil)
        XCTAssertEqual(submitted, [])
        XCTAssertEqual(selected, [0])
        view.submit(candidateIndex: 0)
        XCTAssertEqual(submitted, [0])
    }

    func testTerminalClickChoosesExactCandidateIncludingDuplicateText() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        updateLiveTree(view, entries: [
            .init(text: "同じ", tokens: [], candidateIndex: 0),
            .init(text: "同じ", tokens: [], candidateIndex: 1)
        ], selectionIndex: 0)
        openTree(in: view)
        view.submit(candidateIndex: 1)
        XCTAssertEqual(submitted, [1])
    }

    func testLargeTreeKeepsAlternativesCompactAndSelectionKeepsCandidateIndex() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        let many = (0..<500).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        updateLiveTree(view, entries: many, selectionIndex: 0, numbers: [499: "9"])
        openTree(in: view)
        XCTAssertLessThan(buttons(in: view).count, 40, "Offscreen candidates must not allocate hundreds of AppKit controls")

        updateLiveTree(view, entries: many, selectionIndex: 499, numbers: [499: "9"])
        XCTAssertLessThan(buttons(in: view).count, 40)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "候補499" })
        XCTAssertEqual(submitted, [])
        candidateButtons(in: view).compactMap { $0 as? TreeButton }.first { $0.title == "候補499" }?.performClick(nil)
        XCTAssertEqual(submitted, [])
        view.submit(candidateIndex: 499)
        XCTAssertEqual(submitted, [499])

        updateLiveTree(view, entries: many, selectionIndex: 0)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "候補0" }, "Keyboard selection must reveal previously offscreen nodes")
    }

    func testNewCandidatesRefreshReusedNodeTitles() {
        let view = CandidateTreeView()
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        openTree(in: view)
        updateLiveTree(view, entries: [.init(text: "更新", tokens: [], candidateIndex: 0)], selectionIndex: 0)
        XCTAssertEqual(candidateButtons(in: view).map(\.title), ["更新"])
        XCTAssertEqual(view.subviews.compactMap { $0 as? CandidateNavigationView }.count, 1)
    }

    func testChangingAppearancePreservesCandidateActionsAndNeverSubmitsText() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        updateLiveTree(view, entries: entries, selectionIndex: 0)
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
        view.submit(candidateIndex: 1)
        XCTAssertEqual(submitted, [1])
    }

    func testAlternativeClickSelectsItsRealCandidateBeforeExplicitCommit() {
        let view = CandidateTreeView()
        var committed: [Int] = []
        view.onCandidateSubmitted = { committed.append($0) }
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        openTree(in: view)
        buttons(in: view).first { $0.title == "画" }?.performClick(nil)
        XCTAssertEqual(committed, [])
        view.submit(candidateIndex: 1)
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
        updateLiveTree(view, entries: fixture, selectionIndex: 0)
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

    func testCandidateBlockKeepsAVisibleEdgeAgainstAWhiteDocument() throws {
        let view = CandidateTreeView()
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        view.appearance = NSAppearance(named: .aqua)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let edge = try XCTUnwrap(bitmap.colorAt(x: 0, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let inside = try XCTUnwrap(bitmap.colorAt(x: 8, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertEqual(edge.alphaComponent, 1)
        XCTAssertLessThan(edge.brightnessComponent, inside.brightnessComponent,
                          "A white block on a white document needs its border")
        try assertVisibleBlockEdges(view)
    }

    func testCandidateListKeepsAllFourEdgesVisible() throws {
        let view = CandidateTreeView()
        view.update(entries: entries, selectionIndex: 0, enterConfirmsCandidate: true)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        try assertVisibleBlockEdges(view)
    }

    func testScrolledTreeKeepsAllFourEdgesVisible() throws {
        let view = CandidateTreeView()
        let entries = (0..<20).map { index in
            let words = ["候補\(index)"] + (1..<20).map { "文節\($0)" }
            return CandidateTree.Entry(text: words.joined(), tokens: words.map { .init(text: $0) }, candidateIndex: index)
        }
        updateLiveTree(view, entries: entries, selectionIndex: 0)
        openTree(in: view)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(view.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scrollView.documentView)
        let offset = NSPoint(x: document.bounds.width - scrollView.contentSize.width,
                             y: document.bounds.height - scrollView.contentSize.height)
        XCTAssertGreaterThan(offset.x, 0)
        XCTAssertGreaterThan(offset.y, 0)
        try assertVisibleBlockEdges(view)
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertGreaterThan(scrollView.documentVisibleRect.minX, 0)
        XCTAssertGreaterThan(scrollView.documentVisibleRect.minY, 0)
        try assertVisibleBlockEdges(view)
    }

    private func assertVisibleBlockEdges(_ view: CandidateTreeView, file: StaticString = #filePath, line: UInt = #line) throws {
        view.appearance = NSAppearance(named: .aqua)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), file: file, line: line)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let samples = [
            ("left", NSPoint(x: 0, y: view.bounds.midY)),
            ("right", NSPoint(x: view.bounds.maxX - MacCandidateMetrics.borderWidth / 2, y: view.bounds.midY)),
            ("top", NSPoint(x: view.bounds.midX, y: MacCandidateMetrics.borderWidth / 2)),
            ("bottom", NSPoint(x: view.bounds.midX, y: view.bounds.maxY - MacCandidateMetrics.borderWidth / 2))
        ]
        // Bitmap pixels may differ from AppKit points on Retina displays.
        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        // Antialiased edge pixels must still contrast with the white document beneath them.
        let maximumBrightness: CGFloat = 0.9
        for (edge, point) in samples {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))?
                .usingColorSpace(.sRGB), file: file, line: line)
            let brightnessOnWhite = color.brightnessComponent * color.alphaComponent + 1 - color.alphaComponent
            XCTAssertLessThan(brightnessOnWhite, maximumBrightness,
                              "The \(edge) border must remain visible over white: \(color)", file: file, line: line)
        }
    }

    func testKeyboardNavigationRevealsOffscreenChildAndTerminal() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        let tokens = (0..<20).map { CandidateTree.Token(text: "文節\($0)") }
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        updateLiveTree(view, entries: [.init(text: tokens.map(\.text).joined(), tokens: tokens, candidateIndex: 42)],
                    selectionIndex: 42, numbers: [42: "7"])
        openTree(in: view)
        XCTAssertFalse(buttons(in: view).contains { $0.title == "文節19" })
        for _ in 0..<19 { XCTAssertTrue(view.navigate(.right)) }
        XCTAssertTrue(buttons(in: view).contains { $0.title == "文節19" })
        let terminal = candidateButtons(in: view).compactMap { $0 as? TreeButton }.first {
            $0.title == "文節19"
        }
        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
        XCTAssertNotNil(terminal)
        XCTAssertEqual(terminal?.focusedNode, true)
        let geometry = "view=\(view.frame), preferred=\(view.preferredSize), scroll=\(scroll.frame), " +
            "visible=\(scroll.documentVisibleRect), terminal=\(String(describing: terminal?.frame))"
        print("candidate-terminal-layout: \(geometry)")
        XCTAssertTrue(terminal.map { scroll.documentVisibleRect.contains($0.frame) } ?? false,
                      "The terminal word must be fully visible: \(geometry)")
        terminal?.performClick(nil)
        XCTAssertEqual(submitted, [])
        view.submit(candidateIndex: 42)
        XCTAssertEqual(submitted, [42])
        let focusedWords = {
            self.candidateButtons(in: view).compactMap { $0 as? TreeButton }
                .filter(\.focusedNode).map(\.title)
        }
        for step in 0..<19 {
            let before = focusedWords()
            XCTAssertTrue(view.navigate(.left),
                          "Left step \(step + 1) of 19; before=\(before), after=\(focusedWords())")
        }
        XCTAssertTrue(buttons(in: view).contains { $0.title == "文節0" })
        XCTAssertEqual(focusedWords(), ["文節0"])
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
        view.update(entries: entries, selectionIndex: 7, enterConfirmsCandidate: true)
        XCTAssertTrue(view.navigate(.down))
        XCTAssertEqual(selected, [42])
        XCTAssertTrue(try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }
            .first { $0.candidateIndex == 42 }).isAccessibilitySelected())
        XCTAssertTrue(view.navigate(.up))
        XCTAssertEqual(selected, [42, 7])
        XCTAssertTrue(candidateButtons(in: view).isEmpty)
        XCTAssertTrue(view.navigate(.right))
        XCTAssertTrue(candidateButtons(in: view).isEmpty)
        XCTAssertEqual(submitted, [])
    }

    func testChoosingTheAlreadyHighlightedRowStillNotifiesTheInputState() throws {
        let view = CandidateTreeView()
        var selected: [Int] = []
        var submitted: [Int] = []
        view.onSelectionChanged = { selected.append($0) }
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: nil, enterConfirmsCandidate: true)
        XCTAssertFalse(buttons(in: view).contains { $0.accessibilityIdentifier() == "candidate-confirm" })
        XCTAssertTrue(view.navigate(.down))
        XCTAssertEqual(selected, [0], "Down starts at the first real candidate when none was selected")
        try XCTUnwrap(buttons(in: view).compactMap { $0 as? CandidateRowButton }
            .first { $0.candidateIndex == 0 }).performClick(nil)
        XCTAssertEqual(selected, [0, 0], "A pointer selection enters selecting mode even when the index is unchanged")
        XCTAssertEqual(submitted, [])
        view.submit(candidateIndex: 0)
        XCTAssertEqual(submitted, [0])
    }

    func testLiveTreeDrawsBothAlternativeContinuationsWithSeparateTargets() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let paths = [
            ["今日は", "学会", "に行こうと", "思っています"],
            ["きょうは", "学会", "に行こうと", "思っています"],
            ["キョウハ", "学会", "に行こうと", "思っています"],
            ["今日は", "学界", "に行こうと", "思っています"],
            ["今日は", "がっかい", "に行こうと", "思っています"]
        ]
        let entries = paths.enumerated().map { index, words in
            CandidateTree.Entry(text: words.joined(), tokens: words.map { .init(text: $0) }, candidateIndex: index)
        }
        view.update(entries: entries, selectionIndex: 0)
        view.setFrameSize(view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let controls = candidateButtons(in: view)
        // Three distinct parent paths carry 学会, and two local alternatives
        // share the selected parent. All five must have their own hit targets.
        XCTAssertEqual(controls.filter { $0.title == "学会" }.count, 3)
        XCTAssertEqual(controls.filter { $0.title == "に行こうと" }.count, 3)
        XCTAssertEqual(controls.filter { $0.title == "思っています" }.count, 3)
        XCTAssertTrue(controls.contains { $0.title == "学界" })
        XCTAssertTrue(controls.contains { $0.title == "がっかい" })
        for control in controls {
            for other in controls where control !== other {
                XCTAssertFalse(control.frame.intersects(other.frame))
            }
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
    }
}
