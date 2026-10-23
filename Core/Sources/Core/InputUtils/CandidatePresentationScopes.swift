import KanaKanjiConverterModuleWithDefaultDictionary

/// Word edits share consumption counts; resolve each input boundary only once
/// per presentation batch, including the roman input's internal boundaries.
struct CandidatePresentationScopes {
    struct Scope {
        let consumedInputCount: Int
        let commitScope: CandidateCommitScope?
    }

    private let composingText: ComposingText
    private var spans: [(count: ComposingCount, scope: Scope)] = []

    init(composingText: ComposingText) {
        self.composingText = composingText
    }

    mutating func resolve(composingCount: ComposingCount) -> Scope {
        if let cached = spans.first(where: { $0.count == composingCount }) {
            return cached.scope
        }
        var remaining = composingText
        remaining.prefixComplete(composingCount: composingCount)
        let reading = composingText.convertTarget
        let commitScope = reading.hasSuffix(remaining.convertTarget) ? CandidateCommitScope(
            consumedReading: String(reading.dropLast(remaining.convertTarget.count)), remainingReading: remaining.convertTarget
        ) : nil
        let scope = Scope(consumedInputCount: composingText.input.count - remaining.input.count, commitScope: commitScope)
        spans.append((composingCount, scope))
        return scope
    }
}
