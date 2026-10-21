import Foundation

/// Formal input ownership for the opt-in reading process; no converter or learning store is created.
@MainActor
struct DesktopReadingWorker {
    let readingProcessGeneration = UUID().uuidString
    private(set) var settingsRevision = 0
    private var contexts: [String: DesktopReadingContext] = [:]
    private var focusedContext: String?
    private var focusEpoch = 0
    private var appliedSettings: DesktopWorkerSettingsRuntime?
    private let defaults = DesktopWorkerDefaults()

    mutating func process(_ request: DesktopReadingWorkerRequest) throws -> DesktopReadingWorkerResponse {
        let encoded = try JSONEncoder().encode(request)
        guard encoded.count <= DesktopWorkerProtocolLimits.jsonBytes else { throw DesktopReadingProtocolFailure.requestLimit }
        // Direct Swift calls and JSONL enforce the same operation-specific payload shape.
        _ = try JSONDecoder().decode(DesktopReadingWorkerRequest.self, from: encoded)
        var next = self
        let response: DesktopReadingWorkerResponse
        if let appliedSettings {
            response = try appliedSettings.perform { try next.apply(request) }
        } else {
            response = try next.apply(request)
        }
        guard try JSONEncoder().encode(response).count <= DesktopWorkerProtocolLimits.jsonBytes else {
            throw DesktopReadingProtocolFailure.requestLimit
        }
        self = next
        return response
    }

    func rejected(_ error: Error) -> DesktopReadingWorkerResponse {
        var response = response(.error)
        switch error {
        case let failure as DesktopDictionarySyncFailure: response.error = failure.rawValue
        case let failure as DesktopWorkerSettingsFailure: response.error = failure.rawValue
        case let failure as DesktopReadingProtocolFailure: response.error = failure.rawValue
        case let failure as DesktopReadingSession.Failure: response.error = failure.rawValue
        case DesktopReadingCandidates.Failure.staleRequest: response.error = "stale_candidate_request"
        case DesktopReadingCandidates.Failure.selectionActive: response.error = "candidate_selection_active"
        case DesktopReadingCandidates.Failure.unavailableCandidate: response.error = "unavailable_candidate"
        default: response.error = "invalid_reading_request"
        }
        return response
    }

    private mutating func apply(_ request: DesktopReadingWorkerRequest) throws -> DesktopReadingWorkerResponse {
        switch request.operation {
        case "hello":
            var reply = settingsResponse(.process)
            reply.limits = ["jsonBytes": DesktopWorkerProtocolLimits.jsonBytes,
                            "identifierBytes": DesktopWorkerProtocolLimits.identifierBytes,
                            "contextBytes": DesktopWorkerProtocolLimits.contextBytes,
                            "contexts": DesktopWorkerProtocolLimits.contexts]
            return try defaults.adding(to: reply)
        case "settings": return try defaults.adding(to: settingsResponse(.acknowledgement))
        case "configure-settings": return try configureSettings(request)
        case "bind-initial-dictionary": return try bindInitialDictionary(request)
        case "open": return try open(request)
        case "learning-revision": return try updateLearning(request)
        default: return try applyToContext(request)
        }
    }

    private mutating func open(_ request: DesktopReadingWorkerRequest) throws -> DesktopReadingWorkerResponse {
        try validateProcess(DesktopReadingProtocolValidation.required(request.readingProcessGeneration))
        let name = try DesktopReadingProtocolValidation.required(request.context)
        try DesktopReadingProtocolValidation.identifier(name)
        guard contexts[name] == nil else { throw DesktopReadingProtocolFailure.contextAlreadyOpen }
        guard contexts.count < DesktopWorkerProtocolLimits.contexts else { throw DesktopReadingProtocolFailure.requestLimit }
        let reference = try nextReference(context: name)
        var context = DesktopReadingContext(reference: reference)
        if let appliedSettings { context.configureSettings(appliedSettings) }
        contexts[name] = context
        return response(.acknowledgement, reference: reference)
    }

    private mutating func applyToContext(_ request: DesktopReadingWorkerRequest) throws -> DesktopReadingWorkerResponse {
        let reference = try DesktopReadingProtocolValidation.required(request.reference)
        var context = try context(for: reference)
        switch request.operation {
        case "focus-in":
            guard focusedContext == nil else { throw DesktopReadingProtocolFailure.focusActive }
            let surroundings = try DesktopReadingProtocolValidation.required(request.surroundings)
            try DesktopReadingProtocolValidation.surroundings(surroundings)
            context.reference = try nextReference(context: reference.context)
            context.surroundings = surroundings.bounded()
            focusedContext = reference.context
            contexts[reference.context] = context
            return response(.acknowledgement, reference: context.reference)
        case "close":
            guard focusedContext != reference.context else { throw DesktopReadingProtocolFailure.contextActive }
            contexts.removeValue(forKey: reference.context)
            return response(.acknowledgement, reference: reference)
        case "snapshot":
            var reply = response(.input, reference: reference)
            reply.snapshot = context.snapshot()
            return reply
        default:
            guard focusedContext == reference.context else { throw DesktopReadingProtocolFailure.contextNotFocused }
            var reply = try context.process(request, settingsRevision: settingsRevision)
            if request.operation == "focus-out" {
                context.reference = try nextReference(context: reference.context)
                // The input still belongs to the old focus; this is only for subsequent operations.
                reply.nextReference = context.reference
                focusedContext = nil
            }
            contexts[reference.context] = context
            return reply
        }
    }

    private func context(for reference: DesktopReadingContextReference) throws -> DesktopReadingContext {
        try validateProcess(reference.readingProcessGeneration)
        try DesktopReadingProtocolValidation.identifier(reference.context)
        guard reference.focusEpoch >= 0 else { throw DesktopReadingProtocolFailure.invalidRequest }
        guard let context = contexts[reference.context] else { throw DesktopReadingProtocolFailure.unknownContext }
        guard context.reference == reference else { throw DesktopReadingProtocolFailure.staleFocus }
        return context
    }

    private mutating func configureSettings(_ request: DesktopReadingWorkerRequest) throws -> DesktopReadingWorkerResponse {
        try validateProcess(DesktopReadingProtocolValidation.required(request.readingProcessGeneration))
        let revision = try DesktopReadingProtocolValidation.required(request.settingsRevision)
        let settings = try DesktopReadingProtocolValidation.required(request.settings)
        guard try DesktopWorkerSettingsRuntime.isChange(settings, revision: revision,
                                                        currentRevision: settingsRevision, current: appliedSettings,
                                                        dictionaryRevision: request.dictionaryRevision) else {
            return settingsResponse(.acknowledgement)
        }
        guard focusedContext == nil, contexts.values.allSatisfy({ $0.session.canConfigureSettings }) else {
            throw DesktopWorkerSettingsFailure.settingsBusy
        }
        let prepared = try DesktopWorkerSettingsRuntime(settings, dictionaryRevision: request.dictionaryRevision)
        for name in Array(contexts.keys) { contexts[name]?.configureSettings(prepared) }
        appliedSettings = prepared
        settingsRevision = revision
        return settingsResponse(.acknowledgement)
    }

    private mutating func updateLearning(_ request: DesktopReadingWorkerRequest) throws -> DesktopReadingWorkerResponse {
        try validateProcess(DesktopReadingProtocolValidation.required(request.readingProcessGeneration))
        guard appliedSettings == nil else { throw DesktopWorkerSettingsFailure.fullSettingsRequired }
        let revision = try DesktopReadingProtocolValidation.required(request.settingsRevision)
        guard revision >= 0 else { throw DesktopReadingProtocolFailure.invalidRequest }
        guard revision > settingsRevision else { throw DesktopReadingProtocolFailure.staleSettings }
        for name in Array(contexts.keys) {
            try contexts[name]?.session.updateLearningRevision(revision)
            contexts[name]?.reconversion.clear()
        }
        settingsRevision = revision
        return response(.acknowledgement)
    }

    private mutating func bindInitialDictionary(_ request: DesktopReadingWorkerRequest) throws -> DesktopReadingWorkerResponse {
        try validateProcess(DesktopReadingProtocolValidation.required(request.readingProcessGeneration))
        guard let current = appliedSettings else { throw DesktopWorkerSettingsFailure.fullSettingsRequired }
        let revision = try DesktopReadingProtocolValidation.required(request.settingsRevision)
        let settings = try DesktopReadingProtocolValidation.required(request.settings)
        let dictionary = try DesktopReadingProtocolValidation.required(request.dictionaryRevision)
        let bound = try current.bindingDictionary(dictionary, settings: settings, revision: revision, currentRevision: settingsRevision)
        if current.dictionaryRevision == nil {
            // No request from an unversioned dictionary may become valid after this metadata-only change.
            guard contexts.values.allSatisfy({ !$0.hasRequestedDictionaryData }) else {
                throw DesktopDictionarySyncFailure.bindingBusy
            }
            appliedSettings = bound
        }
        return settingsResponse(.acknowledgement)
    }

    private func validateProcess(_ generation: String) throws {
        try DesktopReadingProtocolValidation.identifier(generation)
        guard generation == readingProcessGeneration else { throw DesktopReadingProtocolFailure.wrongProcess }
    }

    private mutating func nextReference(context: String) throws -> DesktopReadingContextReference {
        guard focusEpoch < Int.max else { throw DesktopReadingProtocolFailure.requestLimit }
        focusEpoch += 1
        return .init(context: context, readingProcessGeneration: readingProcessGeneration, focusEpoch: focusEpoch)
    }

    private func response(
        _ kind: DesktopReadingWorkerResponse.Kind, reference: DesktopReadingContextReference? = nil
    ) -> DesktopReadingWorkerResponse {
        .init(kind: kind, readingProcessGeneration: readingProcessGeneration,
              settingsRevision: settingsRevision, reference: reference)
    }

    private func settingsResponse(_ kind: DesktopReadingWorkerResponse.Kind) -> DesktopReadingWorkerResponse {
        var reply = response(kind)
        reply.settingsContract = DesktopWorkerSettingsRuntime.contract
        reply.settings = appliedSettings?.settings
        reply.dictionaryRevision = appliedSettings?.dictionaryRevision
        reply.customInputTableRevisions = appliedSettings?.customInputTableRevisions ?? [:]
        reply.unsupportedFeatures = DesktopWorkerSettingsRuntime.unsupportedFeatures
        return reply
    }
}
