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

    public init(candidate: Candidate, displayContext: CandidatePresentationContext = .init(), consumedInputCount: Int? = nil) {
        self.candidate = candidate
        self.displayContext = displayContext
        self.consumedInputCount = consumedInputCount
    }
}
