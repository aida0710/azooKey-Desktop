/// The original reading consumed by a candidate and the reading left to edit.
public struct CandidateCommitScope: Codable, Equatable, Sendable {
    public let consumedReading: String
    public let remainingReading: String

    public init(consumedReading: String, remainingReading: String) {
        self.consumedReading = consumedReading
        self.remainingReading = remainingReading
    }
}
