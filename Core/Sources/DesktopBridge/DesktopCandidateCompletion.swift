struct DesktopCandidateCompletion: Codable, Equatable, Sendable {
    let authority: CandidateRequestAuthority
    let workerGeneration: String
    let batchID: String
    let candidateID: String
    let commitID: String
    /// Current configuration at commit time, which may differ only in learning mode.
    let settingsRevision: Int
    let privateInput: Bool
}

struct DesktopCandidateCompletionResult: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case completed
        case alreadyCompleted
    }

    let authority: CandidateRequestAuthority
    let workerGeneration: String
    let batchID: String
    let candidateID: String
    let commitID: String
    let status: Status
    /// A learning update was requested; this is not a crash-durable delivery receipt.
    let learningRequested: Bool
}
