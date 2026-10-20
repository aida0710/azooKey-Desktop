import Core

enum DesktopCandidateFailure: String, Error {
    case invalidRequest = "invalid_candidate_request"
    case unsupportedOperation = "unsupported_candidate_operation"
    case unsupportedSettings = "unsupported_candidate_settings"
    case staleAuthority = "stale_candidate_authority"
    case wrongWorkerGeneration = "wrong_candidate_worker_generation"
    case unknownBatch = "unknown_candidate_batch"
    case unknownCandidate = "unknown_candidate_id"
    case batchNotRetained = "candidate_batch_not_retained"
    case requestLimit = "candidate_request_limit"
    case retainedBatchLimit = "candidate_retained_batch_limit"
    case completionLimit = "candidate_completion_limit"
    case commitIDConflict = "candidate_commit_id_conflict"
}

enum DesktopCandidateLimits {
    // These are development-transport bounds; rejection never consumes the reading.
    static let identifierBytes = 512
    static let contextBytes = 16 * 1024
    static let contexts = 64
    static let retainedBatches = 8
    static let requestsPerContext = 16_384
    static let completionsPerContext = 1024
}

enum DesktopCandidateValidation {
    static func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw DesktopCandidateFailure.invalidRequest }
        return value
    }

    static func identifier(_ value: String) throws {
        // Opaque ASCII identifiers avoid canonically equivalent String dictionary keys.
        guard !value.isEmpty, value.utf8.count <= DesktopCandidateLimits.identifierBytes,
              value.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw DesktopCandidateFailure.invalidRequest
        }
    }

    static func authority(_ authority: CandidateRequestAuthority) throws {
        try identifier(authority.context)
        try identifier(authority.readingProcessGeneration)
        try identifier(authority.requestID)
        guard authority.focusEpoch >= 0, authority.compositionRevision >= 0, authority.settingsRevision >= 0 else {
            throw DesktopCandidateFailure.invalidRequest
        }
    }

    static func request(_ request: DesktopCandidateRequest) throws {
        try authority(request.authority)
        guard request.leftContext.utf8.count <= DesktopCandidateLimits.contextBytes,
              request.rightContext.utf8.count <= DesktopCandidateLimits.contextBytes else {
            throw DesktopCandidateFailure.invalidRequest
        }
    }

    static func reference(_ reference: DesktopCandidateBatchReference) throws {
        try authority(reference.authority)
        try identifier(reference.workerGeneration)
        try identifier(reference.batchID)
    }

    static func completion(_ completion: DesktopCandidateCompletion) throws {
        try reference(.init(authority: completion.authority, workerGeneration: completion.workerGeneration,
                            batchID: completion.batchID))
        try identifier(completion.candidateID)
        try identifier(completion.commitID)
        guard completion.settingsRevision >= 0 else { throw DesktopCandidateFailure.invalidRequest }
    }
}
