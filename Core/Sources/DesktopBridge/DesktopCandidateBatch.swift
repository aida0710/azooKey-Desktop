import Core

/// Candidate-only output: no commits, preedit, cursor, or input-state transitions.
struct DesktopCandidateBatch: Codable, Sendable {
    let authority: CandidateRequestAuthority
    let workerGeneration: String
    let batchID: String
    let candidates: [DesktopCandidateItem]
}

/// Ordinary conversion only: nonzero formal consumption, with no debug/action entries.
struct DesktopCandidateItem: Codable, Sendable {
    struct Token: Codable, Sendable {
        let text: String
        let reading: String
    }

    struct Presentation: Codable, Sendable {
        let tokens: [Token]
        let annotation: String?
        let extraValues: [String: String]
        let score: Double?
        let comparisonGroup: Int?
        let commitScope: CandidateCommitScope?
    }

    let candidateID: String
    let text: String
    let composingCount: ComposingCountSnapshot
    let presentation: Presentation
}
