import Core

/// A display-only projection. Each row and node preview names a retained candidate.
struct DesktopCandidateView: Encodable {
    enum Failure: Error, Equatable {
        case invalidIdentity
        case unknownSelection
    }

    struct Options {
        var showRelativeScores = false
        var showCandidateIndex = false
        var focusedDepth = 0
    }

    struct Item: Encodable {
        let index: Int
        let candidateID: String
        let text: String
        let tokens: [DesktopCandidateItem.Token]
        let annotation: String?
        let score: Double?
        let comparisonGroup: Int?
        let commitScope: CandidateCommitScope?
    }

    let candidateReference: DesktopCandidateBatchReference
    let candidates: [Item]
    let selection: Int?
    let nodes: [DesktopSnapshot.Node]
    let columns: [[Int]]
    let selectedPath: [Int]
    let focusedNode: Int?
    let candidatePage: CandidatePage
    let showCandidateIndex: Bool
    let showRelativeScores: Bool

    init(batch: DesktopCandidateBatch, selectedCandidateID: String?, options: Options = .init()) throws {
        guard batch.candidates.allSatisfy({ !$0.candidateID.isEmpty }),
              Set(batch.candidates.map(\.candidateID)).count == batch.candidates.count else {
            throw Failure.invalidIdentity
        }
        let selection = selectedCandidateID.flatMap { id in batch.candidates.firstIndex { $0.candidateID == id } }
        guard selectedCandidateID == nil || selection != nil else {
            throw Failure.unknownSelection
        }
        candidateReference = .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID)
        candidates = batch.candidates.enumerated().map { index, candidate in
            .init(index: index, candidateID: candidate.candidateID, text: candidate.text,
                  tokens: candidate.presentation.tokens, annotation: candidate.presentation.annotation,
                  score: candidate.presentation.score, comparisonGroup: candidate.presentation.comparisonGroup,
                  commitScope: candidate.presentation.commitScope)
        }
        self.selection = selection
        let entries = batch.candidates.enumerated().map { index, candidate in
            CandidateTree.Entry(
                text: candidate.text, tokens: candidate.presentation.tokens.map { .init(text: $0.text, reading: $0.reading) },
                candidateIndex: index, score: candidate.presentation.score, comparisonGroup: candidate.presentation.comparisonGroup,
                annotation: candidate.presentation.annotation, scope: candidate.presentation.commitScope)
        }
        let tree = CandidateTree(entries: entries)
        columns = tree.compactColumns(candidateIndex: selection)
        selectedPath = columns.compactMap(\.first)
        let selectedNodes = selection.flatMap { tree.paths[$0] } ?? []
        focusedNode = selectedNodes.isEmpty ? nil : selectedNodes[min(max(0, options.focusedDepth), selectedNodes.count - 1)]
        candidatePage = .init(entries: entries, selectionIndex: selection)
        showCandidateIndex = options.showCandidateIndex
        showRelativeScores = options.showRelativeScores
        nodes = Self.nodes(tree: tree, selection: selection, options: options)
    }

    private static func nodes(tree: CandidateTree, selection: Int?, options: Options) -> [DesktopSnapshot.Node] {
        let visible = Set(tree.compactColumns(candidateIndex: selection).flatMap { $0 })
        let scores = tree.relativeScores(candidateIndex: selection)
        return tree.nodes.map { node in
            let preview = visible.contains(node.id) ? tree.preview(at: node.id, preserving: selection) : nil
            let score = options.showRelativeScores && visible.contains(node.id)
                ? CandidateScorePresentation(relativeScore: scores[node.id]) : nil
            return .init(id: node.id, text: node.token.text, reading: node.token.reading,
                         parent: node.parentID, children: node.children, terminals: node.terminalCandidateIndices,
                         depth: node.depth, relativeScore: scores[node.id], scorePresentation: score,
                         preview: preview, previewDescription: preview?.detailDescription)
        }
    }
}
