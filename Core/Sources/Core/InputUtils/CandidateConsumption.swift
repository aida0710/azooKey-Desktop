import KanaKanjiConverterModule

/// The formal suffix of an ordinary conversion candidate, without committing or learning.
/// Request identity and permission to select the candidate belong to the calling session.
public struct CandidateConsumption: Sendable {
    public enum Failure: Error, Equatable {
        case emptyComposition
        case noReadingConsumed
        case outsideConversionRange
        case inconsistentSuffix
    }

    public let composingCount: ComposingCount
    public let consumedReading: String
    public let remaining: CompositionState

    public init(composition: CompositionState, count: ComposingCountSnapshot) throws {
        guard !composition.isEmpty else {
            throw Failure.emptyComposition
        }
        let composingCount = try count.validated(for: composition)
        var remaining = composition
        remaining.prefixComplete(composingCount: composingCount)
        let reading = composition.convertTarget
        let suffix = remaining.convertTarget
        // Canonically equivalent strings are not necessarily the same input scalars.
        guard suffix.utf8.count <= reading.utf8.count,
              reading.utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8) else {
            throw Failure.inconsistentSuffix
        }
        let consumedCount = reading.count - suffix.count
        guard consumedCount > 0 else {
            throw Failure.noReadingConsumed
        }
        guard consumedCount <= (composition.conversionRangeEnd ?? reading.count) else {
            throw Failure.outsideConversionRange
        }
        self.composingCount = composingCount
        self.consumedReading = String(reading.dropLast(suffix.count))
        self.remaining = remaining
    }
}
