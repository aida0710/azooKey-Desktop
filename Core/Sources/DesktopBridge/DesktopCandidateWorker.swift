import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Converter ownership for the opt-in live-OFF development process.
@MainActor
final class DesktopCandidateWorker {
    let workerGeneration = UUID().uuidString
    private(set) var settingsRevision = 0
    private let converter: KanaKanjiConverter
    private let directory: URL
    private let resources: URL?
    private let useZenzai: Bool
    private let customInputTableRevisions: [String: String]
    private var sessions: [String: DesktopCandidateSession] = [:]

    init(directory: URL, resources: URL? = nil, useZenzai: Bool = false) throws {
        self.directory = directory
        self.resources = resources
        self.useZenzai = useZenzai
        let memory = directory.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        converter = KanaKanjiConverter.withDefaultDictionary()
        if let table = CustomInputTableStore.load(), CustomInputTableStore.registerIfExists() {
            customInputTableRevisions = [CustomInputTableStore.tableName: CompositionSnapshot.customInputTableRevision(exportedTable: table)]
        } else {
            customInputTableRevisions = [:]
        }
        if !CompiledUserDictionaryStore.hasExportedDictionary(memoryDirectoryURL: memory) {
            try CompiledUserDictionaryStore.exportCurrentDictionaries(memoryDirectoryURL: memory)
        }
    }

    func process(_ message: DesktopCandidateWorkerRequest) throws -> DesktopCandidateWorkerResponse {
        var response = snapshot()
        response.authority = message.authority
        switch message.operation {
        case "candidates":
            let request = try DesktopCandidateValidation.required(message.request)
            response.batch = try candidates(request)
        case "retain":
            let reference = try DesktopCandidateValidation.required(message.reference)
            try session(reference).retain(reference)
            response.reference = reference
        case "release":
            let reference = try DesktopCandidateValidation.required(message.reference)
            try session(reference).release(reference)
            response.reference = reference
        case "complete":
            let completion = try DesktopCandidateValidation.required(message.completion)
            try DesktopCandidateValidation.completion(completion)
            try validateWorker(completion.workerGeneration)
            guard let session = sessions[completion.authority.context] else { throw DesktopCandidateFailure.unknownBatch }
            response.completion = try session.complete(completion, settingsRevision: settingsRevision)
        case "configure-learning":
            try configureLearning(DesktopCandidateValidation.required(message.learning),
                                  revision: DesktopCandidateValidation.required(message.settingsRevision),
                                  generation: DesktopCandidateValidation.required(message.workerGeneration))
            response = snapshot()
        case "close":
            try close(context: DesktopCandidateValidation.required(message.context),
                      readingProcessGeneration: DesktopCandidateValidation.required(message.readingProcessGeneration),
                      workerGeneration: DesktopCandidateValidation.required(message.workerGeneration))
        case "settings":
            break
        default:
            throw DesktopCandidateFailure.unsupportedOperation
        }
        return response
    }

    func rejected(_ error: Error, authority: CandidateRequestAuthority? = nil) -> DesktopCandidateWorkerResponse {
        var response = snapshot()
        if let authority, (try? DesktopCandidateValidation.authority(authority)) != nil { response.authority = authority }
        response.error = (error as? DesktopCandidateFailure)?.rawValue ?? "invalid_candidate_snapshot"
        return response
    }

    func shutdown() {
        for session in sessions.values { session.close() }
        sessions.removeAll()
        converter.commitUpdateLearningData()
    }

    private func candidates(_ request: DesktopCandidateRequest) throws -> DesktopCandidateBatch {
        try DesktopCandidateValidation.request(request)
        guard request.authority.settingsRevision == settingsRevision else { throw DesktopCandidateFailure.staleAuthority }
        // Predictive/AI/action candidates are not part of this first ordinary-conversion transport.
        guard !Config.DebugPredictiveTyping().value else { throw DesktopCandidateFailure.unsupportedSettings }
        let composition = try request.composition.restore(registeredCustomTables: customInputTableRevisions)
        let session: DesktopCandidateSession
        if let existing = sessions[request.authority.context] {
            session = existing
        } else {
            guard sessions.count < DesktopCandidateLimits.contexts else { throw DesktopCandidateFailure.requestLimit }
            session = .init(authority: request.authority, workerGeneration: workerGeneration, converter: converter,
                            directory: directory, resources: resources, useZenzai: useZenzai)
        }
        let batch = try session.candidates(request, composition: composition)
        sessions[request.authority.context] = session
        return batch
    }

    private func configureLearning(_ learning: Config.Learning.Value, revision: Int, generation: String) throws {
        try validateWorker(generation)
        guard revision >= 0 else { throw DesktopCandidateFailure.invalidRequest }
        if revision == settingsRevision, learning == Config.Learning().value {
            return
        }
        guard revision > settingsRevision else { throw DesktopCandidateFailure.staleAuthority }
        converter.commitUpdateLearningData()
        Config.Learning().value = learning
        ConverterLearningConfiguration.apply(learningType: learning.learningType, converter: converter,
                                             memoryDirectoryURL: directory.appendingPathComponent("memory"))
        settingsRevision = revision
    }

    private func session(_ reference: DesktopCandidateBatchReference) throws -> DesktopCandidateSession {
        try DesktopCandidateValidation.reference(reference)
        try validateWorker(reference.workerGeneration)
        guard let session = sessions[reference.authority.context] else { throw DesktopCandidateFailure.unknownBatch }
        return session
    }

    private func close(context: String, readingProcessGeneration: String, workerGeneration: String) throws {
        try DesktopCandidateValidation.identifier(context)
        try DesktopCandidateValidation.identifier(readingProcessGeneration)
        try validateWorker(workerGeneration)
        guard let session = sessions[context] else {
            return
        }
        guard session.readingProcessGeneration == readingProcessGeneration else { throw DesktopCandidateFailure.staleAuthority }
        session.close()
        sessions.removeValue(forKey: context)
    }

    private func validateWorker(_ generation: String) throws {
        try DesktopCandidateValidation.identifier(generation)
        guard generation == workerGeneration else { throw DesktopCandidateFailure.wrongWorkerGeneration }
    }

    private func snapshot() -> DesktopCandidateWorkerResponse {
        .init(workerGeneration: workerGeneration, settingsRevision: settingsRevision,
              learning: Config.Learning().value, customInputTableRevisions: customInputTableRevisions)
    }
}
