import Core

/// Short-lived document authority; preparing a replacement never edits formal input.
struct DesktopReadingReconversion {
    struct Progress {
        var replacement: ReconversionSession.Replacement?
        var readingRequest: DesktopReconversionReadingRequest?
        var reading: String?
        var error: ReconversionSession.Failure?
    }

    private struct Reading {
        let context: ReconversionContext
        var request: DesktopReconversionReadingRequest?
        var input: ReconversionReadingInput?
    }

    private var session = ReconversionSession()
    private var reading: Reading?

    var hasRecentCommit: Bool { session.hasRecentCommit }
    var pendingWorkerGeneration: String? { reading?.request?.workerGeneration }

    mutating func clear() {
        session = ReconversionSession()
        reading = nil
    }

    mutating func recordCommit(_ commits: [String], checkpoint: CompositionCheckpoint?,
                               context: ReconversionContext?, compositionEmpty: Bool) {
        clear()
        guard compositionEmpty, commits.count == 1, let context,
              context.selectionStart <= Int.max - commits[0].utf16.count else { return }
        session.recordCommit(commits[0], checkpoint: checkpoint, context: context)
    }

    mutating func prepareUndo(in context: ReconversionContext) throws -> Progress {
        reading = nil
        session = session.copy()
        return .init(replacement: try session.prepareUndo(in: context))
    }

    mutating func prepareSelection(
        in context: ReconversionContext, reading suppliedReading: String?,
        request: DesktopReconversionReadingRequest?
    ) throws -> Progress {
        reading = nil
        session = session.copy()
        if let suppliedReading {
            return try prepareResolvedSelection(in: context, reading: suppliedReading)
        }
        // Reuse the shared validation before any dictionary request leaves this owner.
        do {
            _ = try session.prepareSelection(in: context, reading: nil)
        } catch ReconversionSession.Failure.readingRequired {
            guard let request, request.text.utf8.elementsEqual(context.selected.utf8) else {
                throw ReconversionSession.Failure.invalidContext
            }
            try request.validate()
            reading = .init(context: context, request: request)
            return .init(readingRequest: request)
        }
        throw ReconversionSession.Failure.invalidContext
    }

    mutating func resolve(_ resolved: DesktopReconversionReadingResult, in context: ReconversionContext) throws -> Progress {
        guard let pending = reading, let request = pending.request, request.matches(resolved.request) else {
            throw ReconversionSession.Failure.staleRequest
        }
        guard pending.context.matchesDocument(context) else {
            clear()
            throw ReconversionSession.Failure.changedContext
        }
        session = session.copy()
        reading = nil
        return try prepareResolvedSelection(in: context, reading: resolved.reading)
    }

    mutating func editReading(_ event: KeyEventCore, in context: ReconversionContext) throws -> Progress {
        guard var pending = reading, pending.input != nil else { throw ReconversionSession.Failure.staleRequest }
        guard pending.context.matchesDocument(context) else {
            clear()
            throw ReconversionSession.Failure.changedContext
        }
        let update = pending.input?.process(event)
        reading = pending
        switch update {
        case .submitted(let value):
            session = session.copy()
            reading = nil
            return try prepareResolvedSelection(in: context, reading: value)
        case .cancelled:
            clear()
            return .init()
        default:
            return .init(reading: pending.input?.text)
        }
    }

    mutating func confirm(_ token: String, in context: ReconversionContext) throws -> ReconversionSession.RestoredComposition {
        session = session.copy()
        let restored = try session.confirm(token, in: context)
        reading = nil
        return restored
    }

    private mutating func prepareResolvedSelection(in context: ReconversionContext, reading value: String?) throws -> Progress {
        guard (value?.unicodeScalars.count ?? 0) <= ReconversionContext.selectionLimit else {
            throw ReconversionSession.Failure.invalidContext
        }
        do {
            return .init(replacement: try session.prepareSelection(in: context, reading: value))
        } catch ReconversionSession.Failure.readingRequired {
            reading = .init(context: context, input: .init())
            return .init(reading: "", error: .readingRequired)
        }
    }
}
