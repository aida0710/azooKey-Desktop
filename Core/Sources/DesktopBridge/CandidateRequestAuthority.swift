/// The reading owner supplies these identities; a candidate reply cannot advance them.
struct CandidateRequestAuthority: Codable, Equatable, Sendable {
    let context: String
    let readingProcessGeneration: String
    let focusEpoch: Int
    let compositionRevision: Int
    let settingsRevision: Int
    let requestID: String
}
