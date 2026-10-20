import Core
@testable import DesktopBridge
import Foundation
import Testing

@Suite struct DesktopCandidateViewTests {
    private struct Fixture {
        let id: String
        let text: String
        var tokens: [DesktopCandidateItem.Token] = []
        var scope = CandidateCommitScope(consumedReading: "にほんご", remainingReading: "")
        var annotation: String?
        var score: Double? = -1
    }

    private func batch(_ fixtures: [Fixture]) throws -> DesktopCandidateBatch {
        .init(authority: .init(context: "field", readingProcessGeneration: "reader",
                               focusEpoch: 2, compositionRevision: 3, settingsRevision: 4, requestID: "request"),
              workerGeneration: "worker", batchID: "batch",
              candidates: try fixtures.map { fixture in
                  .init(candidateID: fixture.id, text: fixture.text,
                        composingCount: try .init(.surfaceCount(fixture.scope.consumedReading.count)),
                        presentation: .init(tokens: fixture.tokens, annotation: fixture.annotation, extraValues: [:],
                                            score: fixture.score, comparisonGroup: fixture.scope.consumedReading.count,
                                            commitScope: fixture.scope))
              })
    }

    @Test func sharedWordsPreviewAnExistingSentenceWithItsOwnContinuation() throws {
        let source = try batch([
            .init(id: "learn", text: "日本語を学ぶ", tokens: [
                .init(text: "日本語", reading: "ニホンゴ"), .init(text: "を", reading: "ヲ"), .init(text: "学ぶ", reading: "マナブ")
            ]),
            .init(id: "speak", text: "日本語で話す", tokens: [
                .init(text: "日本語", reading: "ニホンゴ"), .init(text: "で", reading: "デ"), .init(text: "話す", reading: "ハナス")
            ])
        ])
        let view = try DesktopCandidateView(batch: source, selectedCandidateID: "speak")
        #expect(view.candidates.map(\.candidateID) == ["learn", "speak"])
        #expect(view.selection == 1)
        let shared = try #require(view.nodes.first { $0.text == "日本語" })
        #expect(shared.preview?.candidateIndex == 1)
        #expect(shared.preview?.text == "日本語で話す")
        #expect(shared.preview?.followingText == "で話す")
        let other = try #require(view.nodes.first { $0.text == "を" })
        #expect(other.preview?.candidateIndex == 0)
        #expect(other.preview?.text == "日本語を学ぶ")
        #expect(other.preview?.followingText == "学ぶ")
        #expect(other.preview?.previousFollowingText == "話す")
        #expect(view.nodes.compactMap(\.preview).allSatisfy { source.candidates[$0.candidateIndex].text == $0.text })
    }

    @Test func identicalTextRetainsDifferentReadingScopesAndAnnotations() throws {
        let source = try batch([
            .init(id: "whole", text: "荷", tokens: [.init(text: "荷", reading: "ニホンゴ")], annotation: "whole"),
            .init(id: "prefix", text: "荷", tokens: [.init(text: "荷", reading: "ニ")],
                  scope: .init(consumedReading: "に", remainingReading: "ほんご"), annotation: "prefix")
        ])
        let view = try DesktopCandidateView(batch: source, selectedCandidateID: "prefix")
        #expect(view.candidates.map(\.candidateID) == ["whole", "prefix"])
        #expect(view.nodes.count == 2)
        #expect(view.candidatePage.position == 2)
        let node = try #require(view.nodes.first { $0.id == view.focusedNode })
        #expect(node.preview?.candidateIndex == 1)
        #expect(node.preview?.annotation == "prefix")
        #expect(node.preview?.scope?.consumedReading == "に")
        #expect(node.preview?.scope?.remainingReading == "ほんご")
        #expect(view.candidatePage.items[1].reading == "に")
    }

    @Test func identicalTokensStillKeepTheSelectedConsumptionIdentity() throws {
        let tokens = [DesktopCandidateItem.Token(text: "荷", reading: "ニ")]
        let source = try batch([
            .init(id: "first", text: "荷", tokens: tokens),
            .init(id: "second", text: "荷", tokens: tokens,
                  scope: .init(consumedReading: "に", remainingReading: "ほんご"))
        ])
        let view = try DesktopCandidateView(batch: source, selectedCandidateID: "second")
        #expect(view.nodes.count == 1)
        #expect(view.nodes[0].terminals == [0, 1])
        #expect(view.nodes[0].preview?.candidateIndex == 1)
        #expect(view.nodes[0].preview?.scope?.remainingReading == "ほんご")
    }

    @Test func aLearnedSentenceWithoutRealBoundariesStaysInOneNode() throws {
        let sentence = "東京都に行きました"
        let source = try batch([.init(id: "learned", text: sentence, tokens: [
            .init(text: sentence, reading: "トウキョウトニイキマシタ")
        ])])
        let view = try DesktopCandidateView(batch: source, selectedCandidateID: "learned")
        #expect(view.nodes.count == 1)
        #expect(view.nodes[0].text == sentence)
        #expect(view.nodes[0].preview?.text == sentence)
        #expect(view.columns == [[0]])
    }

    @Test func aTemplateOrDifferentUnicodeRepresentationShowsTheActualCommitText() throws {
        for (text, token) in [("２０２６", "今日"), ("e\u{301}", "é"), ("👩‍💻", "👩")] {
            let source = try batch([.init(id: "exact", text: text, tokens: [.init(text: token, reading: "ニ")])])
            let view = try DesktopCandidateView(batch: source, selectedCandidateID: "exact")
            #expect(view.nodes.count == 1)
            #expect(Array(view.nodes[0].text.utf8) == Array(text.utf8))
            #expect(Array(try #require(view.nodes[0].preview?.text).utf8) == Array(text.utf8))
        }
    }

    @Test func theLastPageKeepsOriginalIndicesAndOpaqueCandidateIDs() throws {
        let source = try batch((0..<50).map { .init(id: "candidate-\($0)", text: "候補\($0)") })
        let view = try DesktopCandidateView(batch: source, selectedCandidateID: "candidate-49",
                                            options: .init(showCandidateIndex: true))
        #expect(view.candidatePage.totalCount == 50)
        #expect(view.candidatePage.position == 50)
        #expect(view.candidatePage.start == 45)
        #expect(view.candidatePage.previousIndex == 36)
        #expect(view.candidatePage.nextIndex == nil)
        #expect(view.candidatePage.items.map(\.index) == Array(45..<50))
        #expect(view.candidates[49].candidateID == "candidate-49")
        #expect(view.showCandidateIndex)
    }

    @Test func togglingScoresPreservesCandidateIdentityAndTheSelectedPreview() throws {
        let source = try batch([
            .init(id: "first", text: "日本語", tokens: [.init(text: "日本語", reading: "ニホンゴ")]),
            .init(id: "second", text: "にほんご", tokens: [.init(text: "にほんご", reading: "ニホンゴ")], score: -2)
        ])
        let hidden = try DesktopCandidateView(batch: source, selectedCandidateID: "second")
        let shown = try DesktopCandidateView(batch: source, selectedCandidateID: "second",
                                             options: .init(showRelativeScores: true))
        #expect(hidden.candidates.map(\.candidateID) == shown.candidates.map(\.candidateID))
        #expect(hidden.columns == shown.columns)
        #expect(hidden.nodes.map(\.preview) == shown.nodes.map(\.preview))
        #expect(hidden.nodes.allSatisfy { $0.scorePresentation == nil })
        #expect(shown.nodes.allSatisfy { $0.scorePresentation != nil })
    }

    @Test func unselectedAndEmptyViewsDoNotInventASelectionOrInputEffects() throws {
        for source in [try batch([.init(id: "only", text: "日本語")]), try batch([])] {
            let view = try DesktopCandidateView(batch: source, selectedCandidateID: nil)
            #expect(view.selection == nil)
            #expect(view.focusedNode == nil)
            #expect(view.candidatePage.position == nil)
            let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as? [String: Any])
            #expect(Set(wire.keys).isDisjoint(with: ["preedit", "cursor", "commits", "inputState", "consumed", "candidateCompletions"]))
            #expect(view.candidateReference.batchID == source.batchID)
        }
    }

    @Test func unknownSelectionsAndDuplicateIdentitiesCannotBecomeDisplayActions() throws {
        let valid = try batch([.init(id: "valid", text: "日本語")])
        #expect(throws: DesktopCandidateView.Failure.unknownSelection) {
            try DesktopCandidateView(batch: valid, selectedCandidateID: "old")
        }
        for id in ["same", ""] {
            let invalid = try batch([.init(id: id, text: "日本語"), .init(id: id, text: "にほんご")])
            #expect(throws: DesktopCandidateView.Failure.invalidIdentity) {
                try DesktopCandidateView(batch: invalid, selectedCandidateID: nil)
            }
        }
    }
}
