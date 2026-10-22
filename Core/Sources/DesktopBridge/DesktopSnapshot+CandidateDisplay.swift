import Core

extension DesktopSnapshot {
    /// The same fields a renderer receives, so a snapshot and the
    /// `candidate-display` operation always produce the same display.
    func candidateDisplayInput(previous: CandidateDisplayInput.PreviousSelection?) -> CandidateDisplayInput {
        CandidateDisplayInput(
            inputState: inputState, preedit: preedit, reading: reading,
            candidates: candidates.map { .init(index: $0.index, text: $0.text, commitScope: $0.commitScope) },
            selection: selection,
            nodes: nodes.map { node in
                .init(id: node.id, text: node.text, reading: node.reading, relativeScore: node.relativeScore,
                      preview: node.preview.map { .init(candidateIndex: $0.candidateIndex, text: $0.text, scope: $0.scope) },
                      previewDescription: node.previewDescription)
            },
            columns: columns, selectedPath: selectedPath, focusedNode: focusedNode,
            candidatePage: .init(candidatePage), showCandidateIndex: showCandidateIndex,
            showRelativeScores: showRelativeScores, candidateTextSize: candidateTextSize, previous: previous
        )
    }
}
