import Core
import Foundation

extension DesktopReadingContext {
    static let reconversionOperations: Set<String> = [
        "undo-commit", "reconvert", "resolve-reconversion", "reconversion-reading",
        "confirm-reconversion", "cancel-reconversion"
    ]

    mutating func processReconversion(
        _ request: DesktopReadingWorkerRequest, settingsRevision: Int
    ) throws -> DesktopReadingWorkerResponse {
        var response = DesktopReadingWorkerResponse(
            kind: request.operation == "confirm-reconversion" ? .input : .acknowledgement,
            readingProcessGeneration: reference.readingProcessGeneration,
            settingsRevision: settingsRevision, reference: reference)
        if request.operation == "cancel-reconversion" {
            reconversion.clear()
            return response
        }
        do {
            guard !surroundings.privateInput else {
                reconversion.clear()
                throw ReconversionSession.Failure.privateInput
            }
            guard session.canConfigureSettings else { throw ReconversionSession.Failure.compositionActive }
            let context = try DesktopReadingProtocolValidation.required(request.reconversionContext)
            guard context.isValid else {
                reconversion.clear()
                throw ReconversionSession.Failure.invalidContext
            }
            guard !context.isSensitive else {
                reconversion.clear()
                throw ReconversionSession.Failure.privateInput
            }
            guard context.canReplace else {
                reconversion.clear()
                throw ReconversionSession.Failure.replacementUnavailable
            }
            if request.operation == "confirm-reconversion" {
                let token = try DesktopReadingProtocolValidation.required(request.reconversionToken)
                try DesktopReadingProtocolValidation.identifier(token)
                let restored = try reconversion.confirm(token, in: context)
                response.snapshot = try session.restoreReconversion(restored)
                _ = try session.compositionSnapshot().encoded()
                surroundings = .init(leftContext: context.before, rightContext: context.after, privateInput: false).bounded()
                return response
            }
            let progress = try advanceReconversion(request, context: context, settingsRevision: settingsRevision)
            response.reconversion = progress.replacement
            response.reconversionReadingRequest = progress.readingRequest
            response.reconversionReading = progress.reading
            response.reconversionError = progress.error?.rawValue
        } catch let failure as ReconversionSession.Failure {
            response.reconversionError = failure.rawValue
            if request.operation == "confirm-reconversion" { response.snapshot = snapshot() }
        }
        return response
    }

    private mutating func advanceReconversion(
        _ request: DesktopReadingWorkerRequest, context: ReconversionContext, settingsRevision: Int
    ) throws -> DesktopReadingReconversion.Progress {
        switch request.operation {
        case "undo-commit":
            return try reconversion.prepareUndo(in: context)
        case "reconvert":
            let readingRequest: DesktopReconversionReadingRequest?
            if request.reading == nil {
                let worker = try DesktopReadingProtocolValidation.required(request.candidateWorkerGeneration)
                try DesktopReadingProtocolValidation.identifier(worker)
                readingRequest = .init(authority: .init(
                    context: reference.context, readingProcessGeneration: reference.readingProcessGeneration,
                    focusEpoch: reference.focusEpoch,
                    compositionRevision: try DesktopReadingProtocolValidation.required(session.snapshot().compositionRevision),
                    settingsRevision: settingsRevision, requestID: UUID().uuidString),
                    workerGeneration: worker, text: context.selected, privateInput: context.isSensitive)
            } else {
                readingRequest = nil
            }
            return try reconversion.prepareSelection(in: context, reading: request.reading, request: readingRequest)
        case "resolve-reconversion":
            let resolved = try DesktopReadingProtocolValidation.required(request.reconversionReadingResult)
            try resolved.request.validate()
            guard resolved.request.authority.settingsRevision == settingsRevision else {
                throw ReconversionSession.Failure.staleRequest
            }
            return try reconversion.resolve(resolved, in: context)
        case "reconversion-reading":
            let event = try DesktopReadingProtocolValidation.required(request.event)
            try DesktopReadingProtocolValidation.event(event)
            return try reconversion.editReading(event, in: context)
        default:
            throw DesktopReadingProtocolFailure.unsupportedOperation
        }
    }
}
