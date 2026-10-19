import Core
import Testing

private func treeToken(_ text: String, _ reading: String = "") -> CandidateTree.Token {
    .init(text: text, reading: reading)
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
