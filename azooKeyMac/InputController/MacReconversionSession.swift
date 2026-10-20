import Carbon
import Cocoa
import Core
import InputMethodKit

/// Reads and replaces only the validated range in the active IMK client.
@MainActor
final class MacReconversionSession {
    struct CommitSource {
        let checkpoint: CompositionCheckpoint
        let context: ReconversionContext
        let client: ObjectIdentifier
    }
    struct ReadingRequest {
        let context: ReconversionContext
        let client: ObjectIdentifier
        var input = ReconversionReadingInput()
    }

    private let session = ReconversionSession()
    private var clientIdentity: ObjectIdentifier?
    private var pendingClientIdentity: ObjectIdentifier?
    private(set) var originalText: String?
    var readingRequest: ReadingRequest?
    var isSensitive: () -> Bool = { IsSecureEventInputEnabled() }

    func clear() {
        session.clear()
        originalText = nil
        clientIdentity = nil
        pendingClientIdentity = nil
        readingRequest = nil
    }

    func beginInput() {
        session.clear()
        pendingClientIdentity = nil
    }

    func captureCommit(from manager: SegmentsManager, client: IMKTextInput) -> CommitSource? {
        guard let checkpoint = manager.compositionCheckpoint(), let context = context(of: client) else {
            return nil
        }
        return .init(checkpoint: checkpoint, context: context, client: ObjectIdentifier(client))
    }

    func commitText(_ text: String, client: IMKTextInput) {
        // A committed reconversion must not be restored into the next marked text,
        // even when its history cannot be recorded. Retire it before client reentry.
        originalText = nil
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func rememberCommit(_ source: CommitSource?, manager: SegmentsManager, client: IMKTextInput) {
        guard manager.isEmpty, let source, source.client == ObjectIdentifier(client),
              let current = context(of: client), current.selected.isEmpty,
              current.after.unicodeScalars.elementsEqual(source.context.after.unicodeScalars) else {
            return
        }
        let range = NSRange(location: source.context.selectionStart,
                            length: current.selectionStart - source.context.selectionStart)
        guard range.length > 0, range.length <= ReconversionContext.selectionLimit * 2,
              let text = read(range, from: client), !text.isEmpty else {
            return
        }
        session.recordCommit(text, checkpoint: source.checkpoint, context: source.context)
        clientIdentity = source.client
    }

    func prepare(undo: Bool, client: IMKTextInput, reading: String?) throws -> ReconversionSession.Replacement {
        guard !isSensitive() else { clear(); throw ReconversionSession.Failure.privateInput }
        guard let context = context(of: client) else { throw ReconversionSession.Failure.replacementUnavailable }
        pendingClientIdentity = ObjectIdentifier(client)
        if undo {
            guard clientIdentity == ObjectIdentifier(client) else { throw ReconversionSession.Failure.noRecentCommit }
            return try session.prepareUndo(in: context)
        }
        let resolvedReading = reading ?? ReconversionReading.resolve(
            context.selected, dictionary: Config.UserDictionary().value.items + Config.SystemUserDictionary().value.items
        )
        return try session.prepareSelection(in: context, reading: resolvedReading)
    }

    func beginReading(client: IMKTextInput) throws {
        guard let context = context(of: client), !context.selected.isEmpty else {
            throw ReconversionSession.Failure.replacementUnavailable
        }
        readingRequest = .init(context: context, client: ObjectIdentifier(client))
    }

    func readingContextIsCurrent(client: IMKTextInput) -> Bool {
        guard let readingRequest, readingRequest.client == ObjectIdentifier(client),
              let current = context(of: client) else {
            return false
        }
        return readingRequest.context.matchesDocument(current)
    }

    func apply(_ replacement: ReconversionSession.Replacement, client: IMKTextInput, manager: SegmentsManager) throws {
        guard pendingClientIdentity == ObjectIdentifier(client) else { throw ReconversionSession.Failure.staleRequest }
        guard !isSensitive(), let current = context(of: client) else {
            clear()
            throw ReconversionSession.Failure.replacementUnavailable
        }
        try session.validateReplacement(replacement.token, in: current)
        let range = current.selected.isEmpty
            ? NSRange(location: current.cursorUTF16 - replacement.text.utf16.count, length: replacement.text.utf16.count)
            : NSRange(location: current.selectionStart, length: current.selected.utf16.count)
        guard let currentText = read(range, from: client),
              currentText.unicodeScalars.elementsEqual(replacement.text.unicodeScalars) else {
            throw ReconversionSession.Failure.changedContext
        }
        // IMK replaces the checked range atomically with marked text. A read-only
        // client that ignores it must not start a second, detached composition.
        client.setMarkedText(replacement.reading,
                             selectionRange: NSRange(location: replacement.reading.utf16.count, length: 0),
                             replacementRange: range)
        let markedRange = client.markedRange()
        var confirmed = false
        defer {
            if !confirmed, client.markedRange() == markedRange,
               markedRange.location == range.location,
               let marked = read(markedRange, from: client),
               marked.unicodeScalars.elementsEqual(replacement.reading.unicodeScalars) {
                client.insertText(replacement.text, replacementRange: markedRange)
            }
        }
        guard markedRange.location == range.location,
              let marked = read(markedRange, from: client),
              marked.unicodeScalars.elementsEqual(replacement.reading.unicodeScalars),
              let removedContext = context(of: client) else {
            session.clear()
            throw ReconversionSession.Failure.replacementUnavailable
        }
        let restored = try session.confirm(replacement.token, in: removedContext)
        confirmed = true
        pendingClientIdentity = nil
        manager.restoreComposition(restored.checkpoint)
        originalText = restored.originalText
        clientIdentity = ObjectIdentifier(client)
        readingRequest = nil
    }

    func restoreOriginal(client: IMKTextInput) {
        guard let originalText, clientIdentity == ObjectIdentifier(client), !isSensitive(),
              client.markedRange().location != NSNotFound, client.markedRange().length > 0 else {
            return
        }
        client.insertText(originalText, replacementRange: NSRange(location: NSNotFound, length: 0))
        self.originalText = nil
    }

    func context(of client: IMKTextInput) -> ReconversionContext? {
        guard !isSensitive() else {
            return nil
        }
        let markedRange = client.markedRange()
        let hasMarkedText = markedRange.location != NSNotFound && markedRange.length > 0
        let range = hasMarkedText ? markedRange : client.selectedRange()
        let length = client.length()
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= length, range.length <= length - range.location,
              range.length <= ReconversionContext.selectionLimit * 2 else {
            return nil
        }
        // Two UTF-16 units can represent one scalar. Trim by scalar after reading.
        let maximumUnits = ReconversionContext.contextLimit * 2
        let beforeLength = min(range.location, maximumUnits)
        let afterStart = range.location + range.length
        guard let before = read(NSRange(location: range.location - beforeLength, length: beforeLength), from: client),
              let selected = hasMarkedText ? "" : read(range, from: client),
              let after = read(NSRange(location: afterStart, length: min(length - afterStart, maximumUnits)), from: client) else {
            return nil
        }
        return .init(before: before, selected: selected, after: after,
                     cursorUTF16: range.location + selected.utf16.count, anchorUTF16: range.location,
                     canReplace: true, isSensitive: false)
    }

    private func read(_ range: NSRange, from client: IMKTextInput) -> String? {
        guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
              range.location <= client.length(), range.length <= client.length() - range.location else {
            return nil
        }
        if range.length == 0 {
            return ""
        }
        var actual = NSRange(location: NSNotFound, length: 0)
        guard let text = client.string(from: range, actualRange: &actual), actual == range else {
            return nil
        }
        return text
    }
}
