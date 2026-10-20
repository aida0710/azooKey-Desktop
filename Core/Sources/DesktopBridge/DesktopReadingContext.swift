import Core
import Foundation

/// One native field's focus-bound reading and the candidate worker currently serving it.
@MainActor
struct DesktopReadingContext {
    var reference: DesktopReadingContextReference
    var session = DesktopReadingSession()
    var surroundings = DesktopReadingSurroundings(leftContext: "", rightContext: "", privateInput: false)
    private var candidateWorkerGeneration: String?

    init(reference: DesktopReadingContextReference) { self.reference = reference }

    mutating func configureSettings(_ runtime: DesktopWorkerSettingsRuntime) {
        session.configureSettings(runtime)
        candidateWorkerGeneration = nil
    }

    mutating func process(_ request: DesktopReadingWorkerRequest, settingsRevision: Int) throws -> DesktopReadingWorkerResponse {
        var response = DesktopReadingWorkerResponse(
            kind: ["key", "reset", "focus-out", "select", "commit-candidate"].contains(request.operation) ? .input : .acknowledgement,
            readingProcessGeneration: reference.readingProcessGeneration, settingsRevision: settingsRevision,
            reference: reference)
        switch request.operation {
        case "key":
            let event = try DesktopReadingProtocolValidation.required(request.event)
            try DesktopReadingProtocolValidation.event(event)
            response.snapshot = try session.key(event, doubleTap: request.doubleTap ?? false)
        case "reset", "focus-out":
            response.snapshot = try session.reset(commit: DesktopReadingProtocolValidation.required(request.submit))
            candidateWorkerGeneration = nil
        case "select", "commit-candidate":
            let selection = try DesktopReadingProtocolValidation.required(request.selection)
            try DesktopReadingProtocolValidation.reference(selection.batch)
            try DesktopReadingProtocolValidation.identifier(selection.candidateID)
            response.snapshot = request.operation == "select"
                ? try session.selectCandidate(selection) : try session.commitCandidate(selection)
        case "prepare-candidates":
            let generation = try DesktopReadingProtocolValidation.required(request.candidateWorkerGeneration)
            try DesktopReadingProtocolValidation.identifier(generation)
            let candidateRequest = try session.prepareCandidates(context: .init(
                context: reference.context, readingProcessGeneration: reference.readingProcessGeneration,
                focusEpoch: reference.focusEpoch, compositionRevision: 0, settingsRevision: settingsRevision,
                leftContext: surroundings.leftContext, rightContext: surroundings.rightContext,
                privateInput: surroundings.privateInput))
            candidateWorkerGeneration = generation
            return .init(kind: .candidates, readingProcessGeneration: reference.readingProcessGeneration,
                         settingsRevision: settingsRevision, reference: reference, candidateRequest: candidateRequest)
        case "adopt-candidates":
            response.candidateReference = try adopt(request)
            response.candidateView = try session.candidateView()
        case "candidate-worker-stopped":
            let generation = try DesktopReadingProtocolValidation.required(request.candidateWorkerGeneration)
            try DesktopReadingProtocolValidation.identifier(generation)
            guard generation == candidateWorkerGeneration else { throw DesktopReadingProtocolFailure.wrongCandidateWorker }
            session.candidateWorkerUnavailable()
            candidateWorkerGeneration = nil
        default:
            throw DesktopReadingProtocolFailure.unsupportedOperation
        }
        if let snapshot = response.snapshot {
            // Apply bounds before the first candidate request, too. The outer worker applies the change atomically.
            _ = try session.compositionSnapshot().encoded()
            surroundings = surroundings.appending(snapshot.commits)
        }
        if request.operation == "key" || request.operation == "select" {
            response.candidateView = try session.candidateView()
        }
        return response
    }

    private mutating func adopt(_ request: DesktopReadingWorkerRequest) throws -> DesktopCandidateBatchReference {
        let batch = try DesktopReadingProtocolValidation.required(request.batch)
        let retained = try DesktopReadingProtocolValidation.required(request.retainedReference)
        try DesktopReadingProtocolValidation.batch(batch)
        try DesktopReadingProtocolValidation.reference(retained)
        guard batch.workerGeneration == candidateWorkerGeneration else {
            throw DesktopReadingProtocolFailure.wrongCandidateWorker
        }
        guard retained == DesktopCandidateBatchReference(
            authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID) else {
            throw DesktopReadingProtocolFailure.retainRequired
        }
        // The coordinator must obtain this exact retain ACK from the candidate worker first.
        return try session.adoptCandidates(batch)
    }
}
