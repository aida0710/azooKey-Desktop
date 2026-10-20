import AppKit
import Core
import XCTest
@testable import azooKeyMac

@MainActor
final class CandidateTreeViewTests: XCTestCase {
    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? buttons(in: child)
        }
    }

    private let entries: [CandidateTree.Entry] = [
        .init(text: "日本語", tokens: [.init(text: "日本"), .init(text: "語")], candidateIndex: 0),
        .init(text: "日本画", tokens: [.init(text: "日本"), .init(text: "画")], candidateIndex: 1)
    ]

    func testScoresExplainRelativeMeaningAndRefreshOnCandidateChange() throws {
        let view = CandidateTreeView()
        let scored: [CandidateTree.Entry] = [
            .init(text: "選択", tokens: [.init(text: "選択", reading: "センタク")], candidateIndex: 0, score: log(69)),
            .init(text: "洗濯", tokens: [.init(text: "洗濯", reading: "センタク")], candidateIndex: 1, score: log(31))
        ]
        view.update(entries: scored, selectionIndex: 0)
        let selection = try XCTUnwrap(buttons(in: view).first { $0.title == "選択" })
        XCTAssertTrue(selection.toolTip?.contains("相対スコア 69") == true)
        XCTAssertTrue(selection.accessibilityLabel()?.contains("確率ではありません") == true)
        view.update(entries: entries, selectionIndex: 0)
        XCTAssertFalse(buttons(in: view).contains { $0.toolTip?.contains("相対スコア 69") == true })
    }

    func testLongAlternativeDoesNotMoveFollowingWords() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        view.update(entries: entries, selectionIndex: 0)
        let before = try XCTUnwrap(buttons(in: view).first { $0.title == "語" }).frame.minX
        view.update(entries: entries + [
            .init(text: "にほんごにゅうりょく", tokens: [], candidateIndex: 2)
        ], selectionIndex: 0)
        let after = try XCTUnwrap(buttons(in: view).first { $0.title == "語" }).frame.minX
        XCTAssertEqual(after, before, "A whole-sentence alternative must not widen the first word's column")
    }

    func testDocumentWidthsKeepEveryBranchInItsWordColumn() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        view.update(entries: entries, selectionIndex: 0, documentWidths: [40, 20])
        let controls = buttons(in: view)
        let first = try XCTUnwrap(controls.first { $0.title == "日本" })
        let chosen = try XCTUnwrap(controls.first { $0.title == "語" })
        let alternative = try XCTUnwrap(controls.first { $0.title == "画" })
        XCTAssertEqual(chosen.frame.minX - first.frame.minX, 40)
        XCTAssertEqual(alternative.frame.minX, chosen.frame.minX)
        XCTAssertEqual(alternative.frame.width, 20)
    }

    func testAlignedLongSentenceDoesNotScrollAndNumbersLeaveScoreRoom() throws {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 1000, height: 180))
        view.update(entries: entries, selectionIndex: 0, numbers: [0: "1"], documentWidths: [810, 20])
        XCTAssertGreaterThan(view.preferredSize.width, 830)
        let controls = buttons(in: view)
        let word = try XCTUnwrap(controls.first { $0.title == "語" })
        let number = try XCTUnwrap(controls.first { $0.title == "1" })
        XCTAssertGreaterThanOrEqual(number.frame.minY, word.frame.maxY + 12,
                                    "The shortcut number must leave the score line unobstructed")
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

    func testReferenceLayoutKeepsChosenSentenceOnOneCompactRow() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        let alternatives = (0..<100).map {
            CandidateTree.Entry(text: "日本語候補\($0)", tokens: [.init(text: "日本語"), .init(text: "候補\($0)")], candidateIndex: $0)
        }
        view.update(entries: alternatives, selectionIndex: 0)
        let visible = buttons(in: view)
        XCTAssertLessThanOrEqual(view.preferredSize.height, 150, "Alternatives must not expand the entire candidate trie")
        XCTAssertLessThan(view.preferredSize.width, 300, "Short words should not occupy fixed wide columns")
        XCTAssertLessThanOrEqual(visible.count, 4, "Show the path and two alternatives at each word")
        let first = visible.first { $0.title == "日本語" }
        let second = visible.first { $0.title == "候補0" }
        XCTAssertNotNil(first)
        XCTAssertNotNil(second, "The entire chosen sentence must be visible without vertical scrolling")
        XCTAssertEqual(first?.frame.minY, second?.frame.minY, "The chosen sentence is a straight top row")
    }

    func testRedrawDoesNotNotifyAndNavigationNotifiesOnce() {
        let view = CandidateTreeView()
        var selections: [Int] = []
        view.onSelectionChanged = { selections.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        XCTAssertEqual(selections, [])
        XCTAssertTrue(view.navigate(.right))
        XCTAssertTrue(view.navigate(.down))
        XCTAssertEqual(selections, [1])
        view.update(entries: entries, selectionIndex: 1)
        XCTAssertEqual(selections, [1])
    }

    func testStaleAndEmptyCandidatesCannotBeSubmitted() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        view.update(entries: [], selectionIndex: nil)
        view.submit(candidateIndex: 0)
        XCTAssertEqual(submitted, [])
        XCTAssertFalse(view.navigate(.down))
    }

    func testTerminalClickChoosesExactCandidateIncludingDuplicateText() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: [
            .init(text: "同じ", tokens: [], candidateIndex: 0),
            .init(text: "同じ", tokens: [], candidateIndex: 1)
        ], selectionIndex: 0)
        view.submit(candidateIndex: 1)
        XCTAssertEqual(submitted, [1])
    }

    func testNumberPageChangeKeepsControlsAndSubmitsCurrentCandidate() {
        let view = CandidateTreeView()
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: entries, selectionIndex: 0, numbers: [0: "1", 1: "2"])
        let originalButtons = buttons(in: view)

        view.update(entries: entries, selectionIndex: 1, numbers: [0: "9", 1: "1"])

        let updatedButtons = buttons(in: view)
        XCTAssertEqual(Set(originalButtons.map(ObjectIdentifier.init)), Set(updatedButtons.map(ObjectIdentifier.init)),
                       "Changing number labels must retain existing tree controls, avoiding a full layout rebuild")
        XCTAssertTrue(updatedButtons.contains { $0.title == "9" })
        XCTAssertEqual(submitted, [])
        updatedButtons.first { $0.title == "9" }?.performClick(nil)
        XCTAssertEqual(submitted, [0], "The retained button still commits its original converter index")
    }

    func testLargeTreeKeepsAlternativesCompactAndSelectionKeepsCandidateIndex() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        let many = (0..<500).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: many, selectionIndex: 0, numbers: [499: "9"])
        XCTAssertLessThan(buttons(in: view).count, 40, "Offscreen candidates must not allocate hundreds of AppKit controls")

        view.update(entries: many, selectionIndex: 499, numbers: [499: "9"])
        XCTAssertLessThan(buttons(in: view).count, 40)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "候補499" })
        XCTAssertEqual(submitted, [])
        buttons(in: view).first { $0.title == "9" }?.performClick(nil)
        XCTAssertEqual(submitted, [499])

        view.update(entries: many, selectionIndex: 0)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "候補0" }, "Keyboard selection must reveal previously offscreen nodes")
    }

    func testNewCandidatesRefreshReusedNodeTitles() {
        let view = CandidateTreeView()
        view.update(entries: entries, selectionIndex: 0)
        view.update(entries: [.init(text: "更新", tokens: [], candidateIndex: 0)], selectionIndex: 0)
        XCTAssertEqual(buttons(in: view).map(\.title), ["更新"])
    }

    func testDuplicateCandidateNumbersDoNotOverlap() {
        let view = CandidateTreeView()
        view.update(entries: [
            .init(text: "同じ", tokens: [], candidateIndex: 0),
            .init(text: "同じ", tokens: [], candidateIndex: 1)
        ], selectionIndex: 1, numbers: [0: "1", 1: "2"])
        XCTAssertEqual(Set(buttons(in: view).map(\.title)), ["同じ", "2"])
    }

    func testAlternativeClickCommitsItsRealCandidateBeforeItMoves() {
        let view = CandidateTreeView()
        var committed: [Int] = []
        view.onCandidateSubmitted = { committed.append($0) }
        view.update(entries: entries, selectionIndex: 0)
        buttons(in: view).first { $0.title == "画" }?.performClick(nil)
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
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
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
        XCTAssertFalse(buttons(in: view).contains { $0.title == "文節19" })
        for _ in 0..<19 { XCTAssertTrue(view.navigate(.right)) }
        XCTAssertTrue(buttons(in: view).contains { $0.title == "文節19" })
        let terminal = buttons(in: view).first { $0.title == "7" }
        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
        XCTAssertNotNil(terminal)
        XCTAssertTrue(terminal.map { scroll.documentVisibleRect.contains($0.frame) } ?? false,
                      "The terminal number must be fully visible, not clipped at the right edge")
        terminal?.performClick(nil)
        XCTAssertEqual(submitted, [42])
        for _ in 0..<19 { XCTAssertTrue(view.navigate(.left)) }
        XCTAssertTrue(buttons(in: view).contains { $0.title == "文節0" })
    }
}
