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
    private let dictionary: DesktopCandidateDictionary
    private var customInputTableRevisions: [String: String]
    private var appliedSettings: DesktopWorkerSettingsRuntime?
    private var sessions: [String: DesktopCandidateSession] = [:]

    init(directory: URL, resources: URL? = nil, useZenzai: Bool = false,
         dictionarySourceStore: UserDictionarySourceStore = .init()) throws {
        self.directory = directory
        self.resources = resources
        self.useZenzai = useZenzai
        let memory = directory.appendingPathComponent("memory", isDirectory: true)
        dictionary = DesktopCandidateDictionary(memoryDirectoryURL: memory, sourceStore: dictionarySourceStore)
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
        if let source = dictionary.applied?.source {
            return try source.perform { try processWithSettings(message) }
        }
        return try processWithSettings(message)
    }

    /// File work stays in the candidate process and cannot hold a reading input reply.
    func processAsync(_ message: DesktopCandidateWorkerRequest) async throws -> DesktopCandidateWorkerResponse {
        if message.operation == "bind-initial-dictionary" {
            return try await bindInitialDictionary(message)
        }
        if message.operation == "prepare-dictionary" {
            try validatePreparation(message)
            let revision = try await dictionary.prepare()
            var response = settingsSnapshot()
            response.preparedDictionaryRevision = revision
            return response
        }
        if message.operation == "configure-settings", let revision = message.dictionaryRevision {
            guard try settingsChange(message) != nil else {
                return settingsSnapshot()
            }
            guard sessions.isEmpty else { throw DesktopWorkerSettingsFailure.settingsBusy }
            let snapshot = try await dictionary.verify(revision)
            // Recheck after file work: callbacks may have opened a context or changed settings.
            try configureSettings(message, dictionarySnapshot: snapshot)
            return settingsSnapshot()
        }
        return try process(message)
    }

    private func processWithSettings(_ message: DesktopCandidateWorkerRequest) throws -> DesktopCandidateWorkerResponse {
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
            (error as? DesktopDictionarySyncFailure)?.rawValue ??
            (error as? UserDictionarySource.Failure)?.rawValue ??
            (error as? DesktopWorkerSettingsFailure)?.rawValue ??
            (error as? DesktopCandidateFailure)?.rawValue ?? "invalid_candidate_snapshot"
        return response
    }

    func shutdown() {
        for session in sessions.values { session.close() }
        sessions.removeAll()
        dictionary.clear()
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
        let items = dictionary.applied?.source.items ?? (Config.UserDictionary().value.items + Config.SystemUserDictionary().value.items)
        let reading = ReconversionReading.resolve(request.text, dictionary: items)
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
                            directory: directory, resources: resources, useZenzai: useZenzai,
                            userDictionaryDirectoryURL: dictionary.applied?.directoryURL)
        }
        let batch = try session.candidates(request, composition: composition)
        sessions[request.authority.context] = session
        return batch
    }

    private func settingsChange(_ message: DesktopCandidateWorkerRequest) throws -> (settings: DesktopWorkerSettings, revision: Int)? {
        let (settings, revision) = try settingsPayload(message)
        guard try DesktopWorkerSettingsRuntime.isChange(settings, revision: revision,
                                                        currentRevision: settingsRevision, current: appliedSettings,
                                                        dictionaryRevision: message.dictionaryRevision) else {
            return nil
        }
        return (settings, revision)
    }

    private func settingsPayload(_ message: DesktopCandidateWorkerRequest) throws -> (settings: DesktopWorkerSettings, revision: Int) {
        try validateWorker(DesktopCandidateValidation.required(message.workerGeneration))
        let revision = try DesktopCandidateValidation.required(message.settingsRevision)
        let settings = try DesktopCandidateValidation.required(message.settings)
        guard message.request == nil, message.reference == nil, message.completion == nil,
              message.learning == nil, message.context == nil, message.readingProcessGeneration == nil,
              message.reconversionReadingRequest == nil else {
            throw DesktopWorkerSettingsFailure.invalidSettings
        }
        return (settings, revision)
    }

    private func dictionaryBinding(_ message: DesktopCandidateWorkerRequest) throws -> DesktopWorkerSettingsRuntime {
        let (settings, revision) = try settingsPayload(message)
        guard let current = appliedSettings else { throw DesktopWorkerSettingsFailure.fullSettingsRequired }
        return try current.bindingDictionary(DesktopCandidateValidation.required(message.dictionaryRevision),
            settings: settings, revision: revision, currentRevision: settingsRevision)
    }

    private func bindInitialDictionary(_ message: DesktopCandidateWorkerRequest) async throws -> DesktopCandidateWorkerResponse {
        let bound = try dictionaryBinding(message)
        if appliedSettings?.dictionaryRevision != nil {
            return settingsSnapshot()
        }
        guard sessions.isEmpty else { throw DesktopDictionarySyncFailure.bindingBusy }
        let snapshot = try await dictionary.verify(DesktopCandidateValidation.required(bound.dictionaryRevision))
        // File work yields the actor. Reject contexts/settings created before this operation resumes.
        let confirmed = try dictionaryBinding(message)
        if appliedSettings?.dictionaryRevision == nil {
            guard sessions.isEmpty else { throw DesktopDictionarySyncFailure.bindingBusy }
            appliedSettings = confirmed
            dictionary.apply(snapshot)
        }
        return settingsSnapshot()
    }

    private func configureSettings(_ message: DesktopCandidateWorkerRequest,
                                   dictionarySnapshot: CompiledUserDictionarySnapshot? = nil) throws {
        guard let (settings, revision) = try settingsChange(message) else {
            return
        }
        guard sessions.isEmpty else { throw DesktopWorkerSettingsFailure.settingsBusy }
        if let expected = message.dictionaryRevision {
            guard dictionarySnapshot?.source.revision == expected else { throw DesktopDictionarySyncFailure.notPrepared }
        }
        let prepared = try DesktopWorkerSettingsRuntime(settings, dictionaryRevision: message.dictionaryRevision)
        converter.commitUpdateLearningData()
        prepared.perform {
            ConverterLearningConfiguration.apply(learningType: settings.learning.learningType, converter: converter,
                                                 memoryDirectoryURL: directory.appendingPathComponent("memory"))
        }
        appliedSettings = prepared
        if let dictionarySnapshot { dictionary.apply(dictionarySnapshot) }
        customInputTableRevisions = prepared.customInputTableRevisions
        settingsRevision = revision
    }

    private func validatePreparation(_ message: DesktopCandidateWorkerRequest) throws {
        try validateWorker(DesktopCandidateValidation.required(message.workerGeneration))
        guard message.request == nil, message.reference == nil, message.completion == nil,
              message.settingsRevision == nil, message.learning == nil, message.context == nil,
              message.readingProcessGeneration == nil, message.settings == nil,
              message.dictionaryRevision == nil, message.reconversionReadingRequest == nil else {
            throw DesktopCandidateFailure.invalidRequest
        }
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
        response.dictionaryRevision = appliedSettings?.dictionaryRevision
        response.unsupportedFeatures = DesktopWorkerSettingsRuntime.unsupportedFeatures
        return response
    }
}
