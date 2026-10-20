extension CandidatePresentation {
    public func treeEntry(index: Int) -> CandidateTree.Entry {
        .init(text: candidate.text,
              tokens: candidate.data.map { .init(text: $0.word, reading: $0.ruby) },
              candidateIndex: index, score: Double(candidate.value), comparisonGroup: consumedInputCount,
              annotation: displayContext.annotationText, scope: commitScope)
    }
}
