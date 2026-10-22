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
            let numbered = display.nodes.compactMap(\.number)
            #expect(!numbered.isEmpty && numbered.allSatisfy { (1...9).contains($0) })
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

    @Test func upAndDownMoveBetweenSiblingsOnceTheListShowsTheTree() throws {
        try withSession(liveConversion: true, treeCandidates: true) { session in
            _ = type("watashihanihongowobenkyoushiteimasu", into: session)
            _ = session.key(key(49))
            _ = session.key(key(49))
            _ = session.key(key(124))
            try #require(session.key(key(124)).candidateDisplay?.expandTree == true)
            // Back on the first word, which has alternatives such as 私 and 渡し.
            var shown = session.key(key(123))
            for _ in 0..<4 where shown.nodes.first(where: { $0.id == shown.focusedNode })?.depth != 0 {
                shown = session.key(key(123))
            }
            let focused = try #require(shown.nodes.first { $0.id == shown.focusedNode })
            let siblings = shown.nodes.filter { $0.parent == focused.parent && $0.depth == focused.depth }
            try #require(siblings.count > 1)

            let moved = session.key(key(125))
            let movedFocus = try #require(moved.nodes.first { $0.id == moved.focusedNode })
            #expect(movedFocus.id != focused.id)
            #expect(movedFocus.parent == focused.parent && movedFocus.depth == focused.depth)

            // Leaving the selection closes the tree; the next list starts on its rows again.
            _ = session.key(key(53))
            _ = session.key(key(49))
            let relisted = session.key(key(49))
            let first = try #require(relisted.selection)
            #expect(session.key(key(125)).selection == first + 1)
        }
    }

    @Test func layoutAndDisplayOperationsNeedNoSession() throws {
        let layout = try JSONDecoder().decode(BridgeRequest.self, from: Data("""
        {"operation":"candidate-layout","layout":{"mode":"list","textSize":"large","textScale":1,"measuredFontSize":24,
         "columns":[{"nodes":[{"id":0,"parent":null}],"textWidth":48}],"showScores":false,"showNumbers":false,
         "cursor":{"x":10,"y":10,"width":0,"height":20},"workArea":{"x":0,"y":0,"width":800,"height":600}}}
        """.utf8))
        let laidOut = try #require(try DesktopCandidateController.response(to: layout)?.candidateLayout)
        #expect(laidOut.tree.metrics.fontSize == 24 && laidOut.popupWidth == 560)
        #expect(laidOut.placementStatus == .notRequested)

        let display = try JSONDecoder().decode(BridgeRequest.self, from: Data("""
        {"operation":"candidate-display","snapshot":{"inputState":"composing","nodes":[{"id":0,"text":"日本","reading":"ニホン",
         "preview":{"candidateIndex":0,"text":"日本"}}],"columns":[[0]],"selectedPath":[0],"selection":0,
         "candidates":[{"index":0,"text":"日本"}]}}
        """.utf8))
        let shown = try #require(try DesktopCandidateController.response(to: display)?.candidateDisplay)
        #expect(shown.mode == .tree && shown.nodes.map(\.number) == [1])
        #expect(try DesktopCandidateController.response(to: JSONDecoder().decode(
            BridgeRequest.self, from: Data(#"{"operation":"key"}"#.utf8))) == nil)
    }
}
