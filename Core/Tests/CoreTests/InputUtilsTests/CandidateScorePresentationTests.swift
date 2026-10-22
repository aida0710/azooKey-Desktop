import Core
import Foundation
import Testing

@Test func candidateScoreExplainsAConditionalHundredAfterALowScoringParent() throws {
    let tree = CandidateTree(entries: [
        .init(text: "甲語", tokens: [.init(text: "甲", reading: "コウ"), .init(text: "語", reading: "ゴ")],
              candidateIndex: 0, score: log(1), comparisonGroup: 5),
        .init(text: "乙語", tokens: [.init(text: "乙", reading: "コウ"), .init(text: "語", reading: "ゴ")],
              candidateIndex: 1, score: log(99), comparisonGroup: 5)
    ])
    let path = try #require(tree.paths[0])
    let scores = tree.relativeScores(candidateIndex: 0)
    #expect(scores[path[0]] == 1)
    #expect(scores[path[1]] == 100)
    let parent = CandidateScorePresentation(relativeScore: scores[path[0]])
    let child = CandidateScorePresentation(relativeScore: scores[path[1]])
    #expect(parent.label == "1")
    #expect(child.label == "100")
    #expect(child.detailDescription.contains(Localization.text("candidate.score.conditional100")))
    #expect(child.detailDescription.contains(CandidateScorePresentation.explanation))
}

@Test func candidateScoreDistinguishesRoundedZeroFromUnavailableEvaluation() throws {
    let tree = CandidateTree(entries: [
        .init(text: "甲", tokens: [.init(text: "甲", reading: "コウ")], candidateIndex: 0, score: -10000),
        .init(text: "乙", tokens: [.init(text: "乙", reading: "コウ")], candidateIndex: 1, score: 0),
        .init(text: "丙", tokens: [.init(text: "丙", reading: "コウ")], candidateIndex: 2)
    ])
    let scores = tree.relativeScores(candidateIndex: 0)
    let rounded = CandidateScorePresentation(relativeScore: scores[try #require(tree.paths[0]?.first)])
    let unknown = CandidateScorePresentation(relativeScore: scores[try #require(tree.paths[2]?.first)])
    #expect(rounded.label == "0")
    #expect(rounded.detailDescription.contains(Localization.text("candidate.score.roundedZero")))
    #expect(unknown.label == "—")
    #expect(unknown.detailDescription == Localization.text("candidate.score.unavailable"))
}

@Test func candidateScoreExplainsWhyOneEvaluatedCandidateHasAHundred() throws {
    let tree = CandidateTree(entries: [
        .init(text: "候補", tokens: [.init(text: "候補", reading: "コウホ")], candidateIndex: 0, score: -10000)
    ])
    let score = tree.relativeScores(candidateIndex: 0)[try #require(tree.paths[0]?.first)]
    let presentation = CandidateScorePresentation(relativeScore: score)
    #expect(presentation.label == "100")
    #expect(presentation.detailDescription.contains(Localization.text("candidate.score.conditional100")))
}

@Test func candidateScoreIncludesHiddenAlternativesWithoutCountingDuplicatesOrOtherInputRanges() throws {
    let entries: [CandidateTree.Entry] = (0..<4).map {
        .init(text: "候補\($0)", tokens: [.init(text: "候補\($0)", reading: "コウホ")],
              candidateIndex: $0, score: 0, comparisonGroup: 5)
    } + [
        .init(text: "候補0", tokens: [.init(text: "候補0", reading: "コウホ")], candidateIndex: 4, score: 0, comparisonGroup: 5),
        .init(text: "別範囲", tokens: [.init(text: "別範囲", reading: "コウホ")], candidateIndex: 5, score: 100, comparisonGroup: 6)
    ]
    let tree = CandidateTree(entries: entries)
    #expect(tree.compactColumns(candidateIndex: 0).first?.count == 3)
    let scores = tree.relativeScores(candidateIndex: 0)
    let shown = CandidateScorePresentation(relativeScore: scores[try #require(tree.paths[0]?.first)])
    #expect(shown.label == "25")
    #expect(shown.detailDescription.contains(CandidateScorePresentation.explanation))
    #expect(scores[try #require(tree.paths[5]?.first)] == nil)
}
