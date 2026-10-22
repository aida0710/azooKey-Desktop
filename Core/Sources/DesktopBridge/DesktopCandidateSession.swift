import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Candidate lifetimes for one reading context; all live input remains in the reading owner.
@MainActor
final class DesktopCandidateSession {
    private struct Completed {
        let request: DesktopCandidateCompletion
        let response: DesktopCandidateCompletionResult
    }

    let context: String
    let readingProcessGeneration: String
    private let workerGeneration: String
    private let converter: KanaKanjiConverter
    private let directory: URL
    private let resources: URL?
    private let useZenzai: Bool
    private let userDictionaryDirectoryURL: URL?
    private var latestAuthority: CandidateRequestAuthority?
    private var latestBatchID: String?
    private var batches: [String: DesktopCandidateConversion] = [:]
    private var requestIDs: Set<String> = []
    private var completed: [String: Completed] = [:]

    init(authority: CandidateRequestAuthority, workerGeneration: String, converter: KanaKanjiConverter,
         directory: URL, resources: URL?, useZenzai: Bool, userDictionaryDirectoryURL: URL? = nil) {
        context = authority.context
        readingProcessGeneration = authority.readingProcessGeneration
        self.workerGeneration = workerGeneration
        self.converter = converter
        self.directory = directory
        self.resources = resources
        self.useZenzai = useZenzai
        self.userDictionaryDirectoryURL = userDictionaryDirectoryURL
    }

    func candidates(_ request: DesktopCandidateRequest, composition: CompositionState) throws -> DesktopCandidateBatch {
        try validateOwner(request.authority)
        guard !requestIDs.contains(request.authority.requestID) else { throw DesktopCandidateFailure.staleAuthority }
        if let latestAuthority {
            guard request.authority.focusEpoch >= latestAuthority.focusEpoch,
                  request.authority.compositionRevision >= latestAuthority.compositionRevision else {
                throw DesktopCandidateFailure.staleAuthority
            }
        }
        guard requestIDs.count < DesktopCandidateLimits.requestsPerContext else { throw DesktopCandidateFailure.requestLimit }
        if request.privateInput { converter.commitUpdateLearningData() }
        let conversion = DesktopCandidateConversion(request: request, composition: composition, converter: converter,
                                                     directory: directory, resources: resources, useZenzai: useZenzai,
                                                     userDictionaryDirectoryURL: userDictionaryDirectoryURL)
        if let latestBatchID, let previous = batches[latestBatchID], !previous.retained {
            previous.release()
            batches.removeValue(forKey: latestBatchID)
        }
        let batchID = UUID().uuidString
        batches[batchID] = conversion
        latestBatchID = batchID
        latestAuthority = request.authority
        requestIDs.insert(request.authority.requestID)
        return .init(authority: request.authority, workerGeneration: workerGeneration,
                     batchID: batchID, candidates: conversion.items.map(\.item), mainCandidateID: conversion.mainCandidateID)
    }

    func retain(_ reference: DesktopCandidateBatchReference) throws {
        let batch = try batch(reference)
        if !batch.retained {
            guard batches.values.filter(\.retained).count < DesktopCandidateLimits.retainedBatches else {
                throw DesktopCandidateFailure.retainedBatchLimit
            }
            batch.retain()
        }
    }

    func release(_ reference: DesktopCandidateBatchReference) throws {
        let batch = try batch(reference)
        batch.release()
        batches.removeValue(forKey: reference.batchID)
    }

    func complete(_ request: DesktopCandidateCompletion, settingsRevision: Int) throws -> DesktopCandidateCompletionResult {
        try validateOwner(request.authority)
        if let saved = completed[request.commitID] {
            guard saved.request == request else { throw DesktopCandidateFailure.commitIDConflict }
            return .init(authority: saved.response.authority, workerGeneration: workerGeneration,
                         batchID: saved.response.batchID, candidateID: saved.response.candidateID,
                         commitID: saved.response.commitID, status: .alreadyCompleted,
                         learningRequested: saved.response.learningRequested)
        }
        guard request.settingsRevision == settingsRevision else { throw DesktopCandidateFailure.staleAuthority }
        let batch = try batch(.init(authority: request.authority, workerGeneration: request.workerGeneration, batchID: request.batchID))
        guard batch.retained else { throw DesktopCandidateFailure.batchNotRetained }
        let item = try batch.item(id: request.candidateID)
        _ = try CandidateConsumption(composition: batch.composition, count: item.item.composingCount)
        guard completed.count < DesktopCandidateLimits.completionsPerContext else { throw DesktopCandidateFailure.completionLimit }
        // Retire before the side effect. A lost ACK can only replay the saved result in
        // this worker; a process crash must never trigger automatic learning delivery.
        batches.removeValue(forKey: request.batchID)
        let learningRequested = batch.complete(item, privateInput: request.privateInput)
        let response = DesktopCandidateCompletionResult(
            authority: request.authority, workerGeneration: workerGeneration, batchID: request.batchID,
            candidateID: request.candidateID, commitID: request.commitID, status: .completed,
            learningRequested: learningRequested)
        completed[request.commitID] = .init(request: request, response: response)
        return response
    }

    func close() {
        for batch in batches.values { batch.release() }
        batches.removeAll()
        completed.removeAll()
        requestIDs.removeAll()
        latestAuthority = nil
        latestBatchID = nil
    }

    private func validateOwner(_ authority: CandidateRequestAuthority) throws {
        guard authority.context == context, authority.readingProcessGeneration == readingProcessGeneration else {
            throw DesktopCandidateFailure.staleAuthority
        }
    }

    private func batch(_ reference: DesktopCandidateBatchReference) throws -> DesktopCandidateConversion {
        try validateOwner(reference.authority)
        guard reference.workerGeneration == workerGeneration else { throw DesktopCandidateFailure.wrongWorkerGeneration }
        guard let batch = batches[reference.batchID], batch.request.authority == reference.authority else {
            throw DesktopCandidateFailure.unknownBatch
        }
        return batch
    }
}
