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
    private var customInputTableRevisions: [String: String]
    private var appliedSettings: DesktopWorkerSettingsRuntime?
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
        if let appliedSettings {
            return try appliedSettings.perform { try apply(message) }
        }
        return try apply(message)
    }

    private func apply(_ message: DesktopCandidateWorkerRequest) throws -> DesktopCandidateWorkerResponse {
        var response = snapshot()
        response.authority = message.authority
        switch message.operation {
        case "candidates":
            let request = try DesktopCandidateValidation.required(message.request)
            response.batch = try candidates(request)
        case "retain", "release":
            response.reference = try updateRetention(message)
        case "complete":
            let completion = try DesktopCandidateValidation.required(message.completion)
            try DesktopCandidateValidation.completion(completion)
            try validateWorker(completion.workerGeneration)
            guard let session = sessions[completion.authority.context] else { throw DesktopCandidateFailure.unknownBatch }
            response.completion = try session.complete(completion, settingsRevision: settingsRevision)
        case "configure-settings":
            try configureSettings(message)
            response = settingsSnapshot()
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
            response = settingsSnapshot()
        case "resolve-reconversion-reading":
            response.reconversionReadingResult = try resolveReading(
                DesktopCandidateValidation.required(message.reconversionReadingRequest))
        default:
            throw DesktopCandidateFailure.unsupportedOperation
        }
        return response
    }

    func rejected(_ error: Error, authority: CandidateRequestAuthority? = nil) -> DesktopCandidateWorkerResponse {
        var response = snapshot()
        if let authority, (try? DesktopCandidateValidation.authority(authority)) != nil { response.authority = authority }
        response.error = (error as? ReconversionSession.Failure)?.rawValue ??
            (error as? DesktopWorkerSettingsFailure)?.rawValue ??
            (error as? DesktopCandidateFailure)?.rawValue ?? "invalid_candidate_snapshot"
        return response
    }

    func shutdown() {
        for session in sessions.values { session.close() }
        sessions.removeAll()
        converter.commitUpdateLearningData()
    }

    private func updateRetention(_ message: DesktopCandidateWorkerRequest) throws -> DesktopCandidateBatchReference {
        let reference = try DesktopCandidateValidation.required(message.reference)
        let owner = try session(reference)
        if message.operation == "retain" {
            try owner.retain(reference)
        } else {
            try owner.release(reference)
        }
        return reference
    }

    private func resolveReading(_ request: DesktopReconversionReadingRequest) throws -> DesktopReconversionReadingResult {
        try request.validate()
        try validateWorker(request.workerGeneration)
        guard request.authority.settingsRevision == settingsRevision else { throw DesktopCandidateFailure.staleAuthority }
        let reading = ReconversionReading.resolve(request.text, dictionary:
            Config.UserDictionary().value.items + Config.SystemUserDictionary().value.items)
        return .init(request: request, reading: reading)
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

    private func configureSettings(_ message: DesktopCandidateWorkerRequest) throws {
        try validateWorker(DesktopCandidateValidation.required(message.workerGeneration))
        let revision = try DesktopCandidateValidation.required(message.settingsRevision)
        let settings = try DesktopCandidateValidation.required(message.settings)
        guard message.request == nil, message.reference == nil, message.completion == nil,
              message.learning == nil, message.context == nil, message.readingProcessGeneration == nil,
              message.reconversionReadingRequest == nil else {
            throw DesktopWorkerSettingsFailure.invalidSettings
        }
        guard try DesktopWorkerSettingsRuntime.isChange(settings, revision: revision,
                                                        currentRevision: settingsRevision, current: appliedSettings) else {
            return
        }
        guard sessions.isEmpty else { throw DesktopWorkerSettingsFailure.settingsBusy }
        let prepared = try DesktopWorkerSettingsRuntime(settings)
        converter.commitUpdateLearningData()
        prepared.perform {
            ConverterLearningConfiguration.apply(learningType: settings.learning.learningType, converter: converter,
                                                 memoryDirectoryURL: directory.appendingPathComponent("memory"))
        }
        appliedSettings = prepared
        customInputTableRevisions = prepared.customInputTableRevisions
        settingsRevision = revision
    }

    private func configureLearning(_ learning: Config.Learning.Value, revision: Int, generation: String) throws {
        try validateWorker(generation)
        guard appliedSettings == nil else { throw DesktopWorkerSettingsFailure.fullSettingsRequired }
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
              learning: appliedSettings?.settings.learning ?? Config.Learning().value,
              customInputTableRevisions: customInputTableRevisions)
    }

    private func settingsSnapshot() -> DesktopCandidateWorkerResponse {
        var response = snapshot()
        response.settingsContract = DesktopWorkerSettingsRuntime.contract
        response.settings = appliedSettings?.settings
        response.unsupportedFeatures = DesktopWorkerSettingsRuntime.unsupportedFeatures
        return response
    }
}
