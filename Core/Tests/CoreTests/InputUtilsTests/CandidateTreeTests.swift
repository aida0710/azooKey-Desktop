import Core
import Foundation
import Testing

private func treeToken(_ text: String, _ reading: String = "") -> CandidateTree.Token {
    .init(text: text, reading: reading)
}

@Test func candidateTreeScoresAreConditionalRelativeWeights() {
    let tree = CandidateTree(entries: [
        .init(text: "候補を選択", tokens: [treeToken("候補を", "コウホヲ"), treeToken("選択", "センタク")], candidateIndex: 0, score: log(69)),
        .init(text: "候補を洗濯", tokens: [treeToken("候補を", "コウホヲ"), treeToken("洗濯", "センタク")], candidateIndex: 1, score: log(27)),
        .init(text: "候補をせんたく", tokens: [treeToken("候補を", "コウホヲ"), treeToken("せんたく", "センタク")], candidateIndex: 2, score: log(4)),
        // A first-clause result must not swamp complete-sentence scores.
        .init(text: "候補を", tokens: [treeToken("候補を", "コウホヲ")], candidateIndex: 3, score: 999)
    ])
    let scores = tree.relativeScores(candidateIndex: 0)
    #expect(scores[tree.paths[0]![0]] == 100)
    #expect(scores[tree.paths[0]![1]] == 69)
    #expect(scores[tree.paths[1]![1]] == 27)
    #expect(scores[tree.paths[2]![1]] == 4)
}

@Test func candidateTreeScoresIgnoreDuplicatesInvalidValuesAndOtherReadings() {
    let tree = CandidateTree(entries: [
        .init(text: "選択", tokens: [treeToken("選択", "センタク")], candidateIndex: 0, score: 10000),
        .init(text: "洗濯", tokens: [treeToken("洗濯", "センタク")], candidateIndex: 1, score: 10000),
        .init(text: "選択", tokens: [treeToken("選択", "センタク")], candidateIndex: 2, score: 10000),
        .init(text: "せんたく", tokens: [treeToken("せんたく", "センタク")], candidateIndex: 3, score: .nan),
        .init(text: "先", tokens: [treeToken("先", "セン")], candidateIndex: 4, score: .infinity),
        .init(text: "別", tokens: [treeToken("別", "ベツ")], candidateIndex: 5, score: 10001)
    ])
    let scores = tree.relativeScores(candidateIndex: 0)
    #expect(scores[tree.paths[0]![0]] == 50)
    #expect(scores[tree.paths[1]![0]] == 50)
    #expect(scores[tree.paths[3]![0]] == nil)
    #expect(scores[tree.paths[5]![0]] == nil)
    #expect(tree.relativeScores(candidateIndex: nil).isEmpty)
}

@Test func candidateTreeDoesNotCompareSameReadingWithDifferentConsumedInput() {
    let tree = CandidateTree(entries: [
        .init(text: "選択", tokens: [treeToken("選択", "センタク")], candidateIndex: 0, score: 0, comparisonGroup: 0),
        .init(text: "洗濯", tokens: [treeToken("洗濯", "センタク")], candidateIndex: 1, score: 0, comparisonGroup: 0),
        .init(text: "せんたく", tokens: [treeToken("せんたく", "センタク")], candidateIndex: 2, score: 1000, comparisonGroup: 1)
    ])
    let scores = tree.relativeScores(candidateIndex: 0)
    #expect(scores[tree.paths[0]![0]] == 50)
    #expect(scores[tree.paths[1]![0]] == 50)
    #expect(scores[tree.paths[2]![0]] == nil)
}

@Test func candidateTreeScoresIncludeHiddenAlternativesAndDoNotInventMissingScores() {
    let entries: [CandidateTree.Entry] = (0..<4).map {
        .init(text: "候補\($0)", tokens: [treeToken("候補\($0)", "コウホ")], candidateIndex: $0, score: -10000)
    }
    let tree = CandidateTree(entries: entries)
    #expect(tree.compactColumns(candidateIndex: 0).first?.count == 3)
    #expect(Set(tree.relativeScores(candidateIndex: 0).values) == [25])
    let unscored = CandidateTree(entries: [.init(text: "語", tokens: [], candidateIndex: 0)])
    #expect(unscored.relativeScores(candidateIndex: 0).isEmpty)
}

@Test func candidateTreeSplitsKanaFallbackUsingRealReadingBoundaries() {
    let tree = CandidateTree(entries: [
        .init(text: "このように候補", tokens: [treeToken("このように", "コノヨウニ"), treeToken("候補", "コウホ")], candidateIndex: 0),
        .init(text: "コノヨウニコウホ", tokens: [treeToken("コノヨウニコウホ", "コノヨウニコウホ")], candidateIndex: 1),
        .init(text: "このようにこうほ", tokens: [treeToken("このようにこうほ", "コノヨウニコウホ")], candidateIndex: 2),
        .init(text: "学習済み文", tokens: [treeToken("学習済み文", "コノヨウニコウホ")], candidateIndex: 3)
    ])
    #expect(tree.paths[1]!.map { tree.nodes[$0].token.text } == ["コノヨウニ", "コウホ"])
    #expect(tree.paths[2]!.map { tree.nodes[$0].token.text } == ["このように", "こうほ"])
    #expect(tree.paths[3]!.count == 1)
    for (index, text) in [(0, "このように候補"), (1, "コノヨウニコウホ"), (2, "このようにこうほ"), (3, "学習済み文")] {
        #expect(tree.paths[index]!.map { tree.nodes[$0].token.text }.joined() == text)
        #expect(tree.preferredCandidate(at: tree.paths[index]!.last!, preserving: index) == index)
    }
}

@Test func candidateTreeKeepsCanonicalEquivalentKanaIntact() {
    for (reading, text) in [("カ\u{3099}", "ガナ"), ("ガ", "カ\u{3099}ナ")] {
        let tree = CandidateTree(entries: [
            .init(text: "画名", tokens: [treeToken("画", reading), treeToken("名", "ナ")], candidateIndex: 0),
            .init(text: text, tokens: [treeToken(text, text)], candidateIndex: 1)
        ])
        #expect(tree.paths[1]!.map { tree.nodes[$0].token.text }.joined().unicodeScalars.elementsEqual(text.unicodeScalars))
    }
}

@Test func candidateTreeCompactColumnsKeepRealSelectedPathAndBoundAlternatives() {
    let tree = CandidateTree(entries: (0..<500).map {
        .init(text: "日本語候補\($0)", tokens: [treeToken("日本語"), treeToken("候補\($0)")], candidateIndex: $0)
    })
    for index in [0, 250, 499] {
        let columns = tree.compactColumns(candidateIndex: index)
        #expect(columns.compactMap(\.first) == tree.paths[index])
        #expect(columns.map(\.count) == [1, 3])
        #expect(columns.flatMap { $0 }.allSatisfy { tree.preferredCandidate(at: $0, preserving: index) != nil })
    }
    #expect(tree.compactColumns(candidateIndex: nil).compactMap(\.first) == tree.paths[0])
    #expect(CandidateTree(entries: []).compactColumns(candidateIndex: nil).isEmpty)
}

@Test func candidateTreeSharesOnlyCommonPrefix() {
    let tree = CandidateTree(entries: [
        .init(text: "日本語入力", tokens: [treeToken("日本語"), treeToken("入力")], candidateIndex: 0),
        .init(text: "日本語表示", tokens: [treeToken("日本語"), treeToken("表示")], candidateIndex: 1)
    ])
    #expect(tree.nodes.count == 3)
    #expect(tree.roots == [0])
    #expect(tree.nodes[0].children == [1, 2])
    #expect(tree.paths[0] == [0, 1])
    #expect(tree.paths[1] == [0, 2])
    #expect(tree.nodes[0].candidateIndices == [0, 1])
}

@Test func candidateTreeDistinguishesReadingsAndParentPaths() {
    let tree = CandidateTree(entries: [
        .init(text: "日本橋", tokens: [treeToken("日本橋", "ニホンバシ")], candidateIndex: 0),
        .init(text: "日本橋", tokens: [treeToken("日本橋", "ニッポンバシ")], candidateIndex: 1),
        .init(text: "新日本橋", tokens: [treeToken("新"), treeToken("日本橋", "ニホンバシ")], candidateIndex: 2)
    ])
    #expect(tree.roots.count == 3)
    #expect(tree.nodes.count == 4)
    #expect(tree.paths[0]?.last != tree.paths[1]?.last)
    #expect(tree.paths[0]?.last != tree.paths[2]?.last)
}

@Test func candidateTreeRetainsPrefixAndDuplicateTerminals() {
    let tree = CandidateTree(entries: [
        .init(text: "日本語", tokens: [treeToken("日本語")], candidateIndex: 4),
        .init(text: "日本語入力", tokens: [treeToken("日本語"), treeToken("入力")], candidateIndex: 7),
        .init(text: "日本語", tokens: [treeToken("日本語")], candidateIndex: 9)
    ])
    #expect(tree.nodes[0].terminalCandidateIndices == [4, 9])
    #expect(tree.preferredCandidate(at: 0, preserving: 7) == 7)
    #expect(tree.preferredCandidate(at: 0, preserving: nil) == 4)
    #expect(tree.paths[9] == [0])
}

@Test func candidateTreeUsesActualTextForTemplatesAndMissingAnalysis() {
    let tree = CandidateTree(entries: [
        .init(text: "2026/10/19", tokens: [treeToken("<date format=\"yyyy/MM/dd\">")], candidateIndex: 0),
        .init(text: "🙂", tokens: [], candidateIndex: 1)
    ])
    #expect(tree.nodes.map(\.token.text) == ["2026/10/19", "🙂"])
    #expect(tree.paths[0] == [0])
    #expect(tree.paths[1] == [1])
}

@Test func candidateTreeNavigationSelectsRealSiblingPaths() {
    let tree = CandidateTree(entries: [
        .init(text: "日本語入力", tokens: [treeToken("日本語"), treeToken("入力")], candidateIndex: 0),
        .init(text: "日本語表示", tokens: [treeToken("日本語"), treeToken("表示")], candidateIndex: 1),
        .init(text: "日本語表示中", tokens: [treeToken("日本語"), treeToken("表示"), treeToken("中")], candidateIndex: 2)
    ])
    var selection = CandidateTreeSelection(tree: tree, candidateIndex: 0)
    #expect(selection.focusedNodeID == 0)
    #expect(selection.move(.right, in: tree) == 0)
    #expect(selection.focusedNodeID == 1)
    #expect(selection.move(.down, in: tree) == 1)
    #expect(selection.focusedNodeID == 2)
    #expect(selection.move(.right, in: tree) == 2)
    #expect(selection.focusedNodeID == 3)
    #expect(selection.move(.left, in: tree) == 2)
    #expect(selection.selectedCandidateIndex == 2)
    #expect(selection.move(.up, in: tree) == 0)
    #expect(selection.move(.up, in: tree) == 1)
}

@Test func candidateTreeRefreshDropsStaleSelection() {
    let oldTree = CandidateTree(entries: [.init(text: "入力", tokens: [], candidateIndex: 20)])
    var selection = CandidateTreeSelection(tree: oldTree, candidateIndex: 20)
    let emptyTree = CandidateTree(entries: [])
    selection.synchronize(tree: emptyTree, candidateIndex: 20)
    #expect(selection.focusedNodeID == nil)
    #expect(selection.selectedCandidateIndex == nil)
    #expect(selection.move(.down, in: emptyTree) == nil)
    #expect(oldTree.preferredCandidate(at: -1, preserving: 20) == nil)
    #expect(oldTree.preferredCandidate(at: 99, preserving: 20) == nil)
}

@Test func candidateTreeRefreshPreservesDepthButUsesNewCandidates() {
    let first = CandidateTree(entries: [.init(text: "日本語入力", tokens: [treeToken("日本語"), treeToken("入力")], candidateIndex: 0)])
    var selection = CandidateTreeSelection(tree: first, candidateIndex: 0)
    _ = selection.move(.right, in: first)
    let next = CandidateTree(entries: [.init(text: "別候補", tokens: [], candidateIndex: 3)])
    selection.synchronize(tree: next, candidateIndex: 3)
    #expect(selection.selectedCandidateIndex == 3)
    #expect(selection.focusedNodeID == 0)
}
