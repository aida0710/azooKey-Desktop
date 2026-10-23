import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
extension DesktopSegmentEditingTests {
    @Test func everySnapshotCarriesTheDisplayOfItsOwnFields() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            let live = type("nihongowobenkyou", into: session)
            let display = try #require(live.candidateDisplay)
            #expect(display.mode == .tree)
            #expect(display.columns == live.columns)
            #expect(display == CandidateDisplay(live.candidateDisplayInput(previous: nil)))
            #expect(!display.nodes.isEmpty)
            #expect(display.announcement == nil, "Typing must not announce every live candidate")

            _ = session.key(key(49))
            let selecting = session.key(key(49))
            let list = try #require(selecting.candidateDisplay)
            #expect(list.mode == .list)
            #expect(list.list?.keyboardConfirmsCandidate == true)
            #expect(list.list?.confirmIndex == selecting.selection)
            let position = String(format: Localization.text("candidate.position"),
                                  String((selecting.selection ?? -1) + 1), String(selecting.candidates.count))
            #expect(list.announcement?.hasPrefix(position) == true)
        }
    }

    @Test func movingToTheNextWordOfTheSameSentenceAsksToShowTheTree() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            _ = type("watashihanihongowobenkyoushiteimasu", into: session)
            _ = session.key(key(49))
            _ = session.key(key(49))
            // The first move enters the following words, choosing a longer sentence.
            let selecting = session.key(key(124))
            #expect(selecting.candidateDisplay?.expandTree == false)
            let moved = session.key(key(124))
            try #require(moved.selectedPath.count > 2)
            #expect(moved.selection == selecting.selection)
            #expect(moved.focusedNode != selecting.focusedNode)
            #expect(moved.candidateDisplay?.expandTree == true)
            #expect(session.snapshot().candidateDisplay?.expandTree == false, "The request is shown once")
        }
    }

    @Test func upAndDownStepThroughTheListRowsWhileTheListHidesTheTree() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            _ = type("watashihanihongowobenkyoushiteimasu", into: session)
            _ = session.key(key(49))
            let listed = session.key(key(49))
            let first = try #require(listed.selection)
            try #require(listed.candidates.count > first + 2)
            #expect(session.key(key(125)).selection == first + 1)
            #expect(session.key(key(125)).selection == first + 2)
            let back = session.key(key(126))
            #expect(back.selection == first + 1)
            #expect(back.candidateDisplay?.mode == .list)
        }
    }

    func focusedWord(of snapshot: DesktopSnapshot) throws -> DesktopSnapshot.Node {
        try #require(snapshot.nodes.first { $0.id == snapshot.focusedNode })
    }

    func isSibling(_ node: DesktopSnapshot.Node, of other: DesktopSnapshot.Node) -> Bool {
        node.id != other.id && node.parent == other.parent && node.depth == other.depth
    }

    /// Converts a sentence and moves to its following words, which asks to
    /// show the tree, then returns to the first word, whose alternatives such
    /// as 私 and 渡し are siblings.
    func expandTreeOnTheFirstWord(_ session: DesktopSession) throws -> DesktopSnapshot {
        _ = type("watashihanihongowobenkyoushiteimasu", into: session)
        _ = session.key(key(49))
        _ = session.key(key(49))
        _ = session.key(key(124))
        try #require(session.key(key(124)).candidateDisplay?.expandTree == true)
        var shown = session.key(key(123))
        for _ in 0..<4 where shown.nodes.first(where: { $0.id == shown.focusedNode })?.depth != 0 {
            shown = session.key(key(123))
        }
        let focused = try focusedWord(of: shown)
        try #require(shown.nodes.contains { isSibling($0, of: focused) })
        return shown
    }

    @Test func upAndDownMoveBetweenSiblingsOnceTheListShowsTheTree() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            let focused = try focusedWord(of: try expandTreeOnTheFirstWord(session))
            #expect(isSibling(try focusedWord(of: session.key(key(125))), of: focused))

            // Leaving the selection closes the tree; the next list starts on its rows again.
            _ = session.key(key(53))
            _ = session.key(key(49))
            let relisted = session.key(key(49))
            let first = try #require(relisted.selection)
            #expect(session.key(key(125)).selection == first + 1)
        }
    }

    @Test func upAndDownStepThroughTheListRowsOnceTheWindowClosesTheTree() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            let shown = try expandTreeOnTheFirstWord(session)
            let first = try #require(shown.selection)
            let focused = try focusedWord(of: shown)
            try #require(shown.candidates.count > first + 1)

            // The user closed the tree with the window's button.
            #expect(session.key(key(125), treeShown: false).selection == first + 1)
            #expect(session.key(key(126), treeShown: false).selection == first)

            // Opened again with the button, the same key reaches a sibling instead of the next row.
            let opened = session.key(key(125), treeShown: true)
            #expect(isSibling(try focusedWord(of: opened), of: focused))
            #expect(opened.selection != first + 1)
        }
    }

    @Test func upAndDownMoveBetweenSiblingsOnceTheWindowOpensTheTree() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            _ = type("watashihanihongowobenkyoushiteimasu", into: session)
            _ = session.key(key(49))
            _ = session.key(key(49))
            // The first move enters the following words without asking for the tree.
            // There the next row's word follows another first word, so it is no sibling.
            let entered = session.key(key(124))
            try #require(entered.candidateDisplay?.expandTree == false)
            let focused = try focusedWord(of: entered)
            try #require(focused.depth > 0 && entered.nodes.contains { isSibling($0, of: focused) })

            // The user opened the tree with the window's button before any response asked for it.
            #expect(isSibling(try focusedWord(of: session.key(key(125), treeShown: true)), of: focused))
        }
    }

    @Test func theTreeShownFactOfAKeyRequestReachesTheSession() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            let first = try #require(try expandTreeOnTheFirstWord(session).selection)
            let request = try JSONDecoder().decode(BridgeRequest.self, from: Data("""
            {"operation":"key","event":{"keyCode":125,"modifierFlags":0},"candidateDisplay":{"treeShown":false}}
            """.utf8))
            let history = AIPromptHistory(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tree-shown-\(UUID().uuidString)/prompts.json"))
            let controller = DesktopAIController(promptHistory: history)
            let moved = controller.key(try #require(request.event), request: request, session: session, context: "field")
            #expect(moved.selection == first + 1)
        }
    }

    @Test func layoutAndDisplayOperationsNeedNoSession() throws {
        let layout = try JSONDecoder().decode(BridgeRequest.self, from: Data("""
        {"operation":"candidate-layout","layout":{"mode":"list","textSize":"large","textScale":1,"measuredFontSize":18,
         "columns":[{"nodes":[{"id":0,"parent":null}],"textWidth":48}],"showScores":false,
         "cursor":{"x":10,"y":10,"width":0,"height":20},"workArea":{"x":0,"y":0,"width":800,"height":600}}}
        """.utf8))
        let laidOut = try #require(try DesktopCandidateController.response(to: layout)?.candidateLayout)
        #expect(laidOut.tree.metrics.fontSize == 18 && laidOut.popupWidth == 430)
        #expect(laidOut.placementStatus == .notRequested)

        let display = try JSONDecoder().decode(BridgeRequest.self, from: Data("""
        {"operation":"candidate-display","snapshot":{"inputState":"composing","nodes":[{"id":0,"text":"日本","reading":"ニホン",
         "preview":{"candidateIndex":0,"text":"日本"}}],"columns":[[0]],"selectedPath":[0],"selection":0,
         "candidates":[{"index":0,"text":"日本"}]}}
        """.utf8))
        let shown = try #require(try DesktopCandidateController.response(to: display)?.candidateDisplay)
        #expect(shown.mode == .tree && shown.nodes.map(\.id) == [0])
        #expect(try DesktopCandidateController.response(to: JSONDecoder().decode(
            BridgeRequest.self, from: Data(#"{"operation":"key"}"#.utf8))) == nil)
    }
}
