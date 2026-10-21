import Core
import Foundation

/// One native field's focus-bound reading and the candidate worker currently serving it.
@MainActor
struct DesktopReadingContext {
    var reference: DesktopReadingContextReference
    var session = DesktopReadingSession()
    var surroundings = DesktopReadingSurroundings(leftContext: "", rightContext: "", privateInput: false)
    var reconversion = DesktopReadingReconversion()
    private var candidateWorkerGeneration: String?

    init(reference: DesktopReadingContextReference) { self.reference = reference }

    mutating func configureSettings(_ runtime: DesktopWorkerSettingsRuntime) {
        session.configureSettings(runtime)
        candidateWorkerGeneration = nil
        reconversion.clear()
    }

    func snapshot() -> DesktopSnapshot {
        var snapshot = session.snapshot()
        snapshot.canUndoCommit = reconversion.hasRecentCommit && session.canConfigureSettings && !surroundings.privateInput
        return snapshot
    }

    mutating func process(_ request: DesktopReadingWorkerRequest, settingsRevision: Int) throws -> DesktopReadingWorkerResponse {
        if Self.reconversionOperations.contains(request.operation) {
            return try processReconversion(request, settingsRevision: settingsRevision)
        }
        var response = DesktopReadingWorkerResponse(
            kind: ["key", "reset", "focus-out", "select", "commit-candidate"].contains(request.operation) ? .input : .acknowledgement,
            readingProcessGeneration: reference.readingProcessGeneration, settingsRevision: settingsRevision,
            reference: reference)
        switch request.operation {
        case "key":
            let event = try DesktopReadingProtocolValidation.required(request.event)
            try DesktopReadingProtocolValidation.event(event)
            response.snapshot = try processInput(request) { try $0.key(event, doubleTap: request.doubleTap ?? false) }
        case "reset", "focus-out":
            response.snapshot = try session.reset(commit: DesktopReadingProtocolValidation.required(request.submit))
            candidateWorkerGeneration = nil
            reconversion.clear()
        case "select", "commit-candidate":
            let selection = try DesktopReadingProtocolValidation.required(request.selection)
            try DesktopReadingProtocolValidation.reference(selection.batch)
            try DesktopReadingProtocolValidation.identifier(selection.candidateID)
            response.snapshot = request.operation == "select"
                ? try session.selectCandidate(selection)
                : try processInput(request) { try $0.commitCandidate(selection) }
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
            try candidateWorkerStopped(DesktopReadingProtocolValidation.required(request.candidateWorkerGeneration))
        default:
            throw DesktopReadingProtocolFailure.unsupportedOperation
        }
        if let snapshot = response.snapshot {
            // Apply bounds before the first candidate request, too. The outer worker applies the change atomically.
            _ = try session.compositionSnapshot().encoded()
            surroundings = surroundings.appending(snapshot.commits)
            response.snapshot?.canUndoCommit = self.snapshot().canUndoCommit
        }
        if request.operation == "key" || request.operation == "select" {
            response.candidateView = try session.candidateView()
        }
        return response
    }

    private mutating func candidateWorkerStopped(_ generation: String) throws {
        try DesktopReadingProtocolValidation.identifier(generation)
        guard generation == candidateWorkerGeneration || generation == reconversion.pendingWorkerGeneration else {
            throw DesktopReadingProtocolFailure.wrongCandidateWorker
        }
        if generation == reconversion.pendingWorkerGeneration { reconversion.clear() }
        session.candidateWorkerUnavailable()
        candidateWorkerGeneration = nil
    }

    private mutating func processInput(
        _ request: DesktopReadingWorkerRequest, operation: (inout DesktopReadingSession) throws -> DesktopSnapshot
    ) throws -> DesktopSnapshot {
        let previousComposition = session.composition
        var checkpoint = session.reconversionCheckpoint()
        let snapshot: DesktopSnapshot
        do {
            snapshot = try operation(&session)
        } catch let failure as ReconversionSession.Failure {
            var unchanged = self.snapshot()
            unchanged.reconversionError = failure.rawValue
            return unchanged
        }
        if snapshot.candidateCompletions?.count == 1, snapshot.commits.count == 1, session.composition.isEmpty {
            // An atomic pointer commit may select only inside the staged operation.
            checkpoint = previousComposition.checkpoint(selectedText: snapshot.commits[0])
        }
        let document = surroundings.privateInput ? nil : request.reconversionContext
        reconversion.recordCommit(snapshot.commits, checkpoint: checkpoint, context: document,
                                  compositionEmpty: session.composition.isEmpty)
        return snapshot
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
