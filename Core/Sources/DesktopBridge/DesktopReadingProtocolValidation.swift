import Core

enum DesktopReadingProtocolFailure: String, Error {
    case invalidRequest = "invalid_reading_request"
    case unsupportedOperation = "unsupported_reading_operation"
    case wrongProcess = "wrong_reading_process_generation"
    case staleFocus = "stale_reading_focus"
    case unknownContext = "unknown_reading_context"
    case contextAlreadyOpen = "reading_context_already_open"
    case focusActive = "reading_focus_already_active"
    case contextNotFocused = "reading_context_not_focused"
    case contextActive = "reading_context_still_active"
    case requestLimit = "reading_request_limit"
    case wrongCandidateWorker = "wrong_candidate_worker_generation"
    case retainRequired = "candidate_retain_ack_required"
    case staleSettings = "stale_reading_settings"
}

enum DesktopReadingProtocolValidation {
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init(intValue: Int) { self.init(stringValue: String(intValue)) }
    }

    static func keys(_ decoder: any Decoder, allowed: Set<String>) throws {
        let values = try decoder.container(keyedBy: Key.self)
        guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DesktopReadingProtocolFailure.invalidRequest
        }
    }

    static func required<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw DesktopReadingProtocolFailure.invalidRequest }
        return value
    }

    static func identifier(_ value: String) throws {
        guard DesktopWorkerIdentifier.isValid(value) else {
            throw DesktopReadingProtocolFailure.invalidRequest
        }
    }

    static func authority(_ authority: CandidateRequestAuthority) throws {
        try identifier(authority.context)
        try identifier(authority.readingProcessGeneration)
        try identifier(authority.requestID)
        guard authority.focusEpoch >= 0, authority.compositionRevision >= 0, authority.settingsRevision >= 0 else {
            throw DesktopReadingProtocolFailure.invalidRequest
        }
    }

    static func reference(_ reference: DesktopCandidateBatchReference) throws {
        try authority(reference.authority)
        try identifier(reference.workerGeneration)
        try identifier(reference.batchID)
    }

    static func batch(_ batch: DesktopCandidateBatch) throws {
        try reference(.init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID))
        for candidate in batch.candidates { try identifier(candidate.candidateID) }
    }

    static func surroundings(_ surroundings: DesktopReadingSurroundings) throws {
        guard surroundings.leftContext.utf8.count <= DesktopWorkerProtocolLimits.contextBytes,
              surroundings.rightContext.utf8.count <= DesktopWorkerProtocolLimits.contextBytes else {
            throw DesktopReadingProtocolFailure.requestLimit
        }
    }

    static func event(_ event: KeyEventCore) throws {
        guard (0...15).contains(event.modifierFlags.rawValue),
              (event.characters?.utf8.count ?? 0) <= CompositionSnapshotLimits.pieceUTF8ByteCount,
              (event.charactersIgnoringModifiers?.utf8.count ?? 0) <= CompositionSnapshotLimits.pieceUTF8ByteCount else {
            throw DesktopReadingProtocolFailure.invalidRequest
        }
    }
}
