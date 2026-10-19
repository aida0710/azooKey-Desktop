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

    func testLargeTreeCreatesOnlyVisibleControlsAndScrollClickKeepsCandidateIndex() {
        let view = CandidateTreeView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        let many = (0..<500).map { CandidateTree.Entry(text: "候補\($0)", tokens: [], candidateIndex: $0) }
        var submitted: [Int] = []
        view.onCandidateSubmitted = { submitted.append($0) }
        view.update(entries: many, selectionIndex: 0, numbers: [499: "9"])
        XCTAssertLessThan(buttons(in: view).count, 40, "Offscreen candidates must not allocate hundreds of AppKit controls")

        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 499 * 64))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertLessThan(buttons(in: view).count, 40)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "候補499" })
        XCTAssertEqual(submitted, [])
        buttons(in: view).first { $0.title == "9" }?.performClick(nil)
        XCTAssertEqual(submitted, [499])

        view.update(entries: many, selectionIndex: 0)
        XCTAssertTrue(buttons(in: view).contains { $0.title == "候補0" }, "Keyboard selection must reveal previously offscreen nodes")
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
