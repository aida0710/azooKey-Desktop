import KanaKanjiConverterModuleWithDefaultDictionary

public struct CandidatePresentationContext: Sendable {
    public var annotationText: String?
    public var extraValues: [String: String]

    public init(annotationText: String? = nil, extraValues: [String: String] = [:]) {
        self.annotationText = annotationText
        self.extraValues = extraValues
    }
}

public struct CandidatePresentation: Sendable {
    public var candidate: Candidate
    public var displayContext: CandidatePresentationContext
    /// Canonical input span, independent of upstream input/surface count units.
    public var consumedInputCount: Int?
    public var commitScope: CandidateCommitScope?
    /// Keeps a multi-element replacement in the original word’s reading range.
    public var treeTokens: [CandidateTree.Token]?

    public init(candidate: Candidate, displayContext: CandidatePresentationContext = .init(),
                consumedInputCount: Int? = nil, commitScope: CandidateCommitScope? = nil,
                treeTokens: [CandidateTree.Token]? = nil) {
        self.candidate = candidate
        self.displayContext = displayContext
        self.consumedInputCount = consumedInputCount
        self.commitScope = commitScope
        self.treeTokens = treeTokens
    }
}
