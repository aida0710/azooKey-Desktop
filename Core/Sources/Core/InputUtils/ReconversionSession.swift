import Foundation

/// Coordinates the one destructive step with an acknowledgement from the host.
/// Each platform keeps one instance per focused input context.
public final class ReconversionSession {
    public enum Failure: String, Error, CaseIterable {
        case privateInput = "private_input"
        case replacementUnavailable = "replacement_unavailable"
        case invalidContext = "invalid_context"
        case noRecentCommit = "no_recent_commit"
        case changedContext = "changed_context"
        case noSelection = "no_selection"
        case readingRequired = "reading_required"
        case staleRequest = "stale_request"
        case compositionActive = "composition_active"
        case wholeSelectionRequired = "whole_selection_required"
    }

    public struct Replacement: Codable, Equatable {
        public let token: String
        public let offset: Int
        public let count: Int
        public let text: String
        public let reading: String
        /// The document the host must report once it has deleted `text`.
        /// Adapters that wait for a deletion acknowledgement compare against it.
        public let removedContext: ReconversionContext
    }

    public struct RestoredComposition {
        public let checkpoint: CompositionCheckpoint
        public let originalText: String
    }

    private struct Commit {
        let text: String
        let checkpoint: CompositionCheckpoint
        let context: ReconversionContext
    }
    private struct Pending {
        let replacement: Replacement
        let checkpoint: CompositionCheckpoint
        let sourceContext: ReconversionContext
    }
    private var recentCommit: Commit?
    private var pending: Pending?

    public init() {}

    public var hasRecentCommit: Bool { recentCommit != nil }

    public func clear() {
        recentCommit = nil
        pending = nil
    }

    public func recordCommit(_ text: String, checkpoint: CompositionCheckpoint?, context: ReconversionContext?) {
        clear()
        guard let checkpoint, let context,
              context.isValid, context.canReplace, !context.isSensitive,
              !text.isEmpty, text.unicodeScalars.count <= ReconversionContext.selectionLimit,
              checkpoint.reading.count <= ReconversionContext.selectionLimit else { return }
        recentCommit = .init(text: text, checkpoint: checkpoint, context: context.replacingSelection(with: text))
    }

    public func prepareUndo(in context: ReconversionContext) throws -> Replacement {
        pending = nil
        try validate(context)
        guard let commit = recentCommit else { throw Failure.noRecentCommit }
        guard commit.context.matchesDocument(context),
              let removedContext = context.removingPreceding(commit.text) else {
            recentCommit = nil
            throw Failure.changedContext
        }
        return prepare(text: commit.text, offset: -commit.text.unicodeScalars.count,
                       checkpoint: commit.checkpoint, sourceContext: context, removedContext: removedContext)
    }

    public func prepareSelection(in context: ReconversionContext, reading: String?) throws -> Replacement {
        pending = nil
        try validate(context)
        guard !context.selected.isEmpty else { throw Failure.noSelection }
        guard let reading, !reading.isEmpty,
              reading.count <= ReconversionContext.selectionLimit else { throw Failure.readingRequired }
        return prepare(text: context.selected, offset: context.cursorUTF16 > context.anchorUTF16 ? -context.selected.unicodeScalars.count : 0,
                       checkpoint: .reading(reading), sourceContext: context, removedContext: context.replacingSelection(with: ""))
    }

    public func validateReplacement(_ token: String, in context: ReconversionContext) throws {
        try validate(context)
        guard let pending, pending.replacement.token == token else { throw Failure.staleRequest }
        guard pending.sourceContext.matchesDocument(context) else { throw Failure.changedContext }
    }

    public func confirm(_ token: String, in context: ReconversionContext) throws -> RestoredComposition {
        try validate(context)
        guard let pending, pending.replacement.token == token else { throw Failure.staleRequest }
        guard pending.replacement.removedContext.matchesDocument(context) else { throw Failure.changedContext }
        self.pending = nil
        recentCommit = nil
        return .init(checkpoint: pending.checkpoint, originalText: pending.replacement.text)
    }

    private func prepare(text: String, offset: Int, checkpoint: CompositionCheckpoint,
                         sourceContext: ReconversionContext, removedContext: ReconversionContext) -> Replacement {
        let replacement = Replacement(token: UUID().uuidString, offset: offset, count: text.unicodeScalars.count,
                                      text: text, reading: checkpoint.reading, removedContext: removedContext)
        pending = .init(replacement: replacement, checkpoint: checkpoint, sourceContext: sourceContext)
        return replacement
    }

    private func validate(_ context: ReconversionContext) throws {
        if context.isSensitive { clear(); throw Failure.privateInput }
        guard context.canReplace else { clear(); throw Failure.replacementUnavailable }
        guard context.isValid else { clear(); throw Failure.invalidContext }
    }
}
