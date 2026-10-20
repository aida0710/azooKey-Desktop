import Core

struct DesktopCandidateRequest: Codable, Sendable {
    let authority: CandidateRequestAuthority
    let composition: CompositionSnapshot
    let leftContext: String
    let rightContext: String
    let privateInput: Bool
}

/// Retaining is explicit so a later calculation cannot destroy a selected candidate.
struct DesktopCandidateBatchReference: Codable, Equatable, Sendable {
    let authority: CandidateRequestAuthority
    let workerGeneration: String
    let batchID: String
}
