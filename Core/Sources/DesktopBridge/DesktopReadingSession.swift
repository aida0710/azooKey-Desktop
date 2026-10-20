import Core
import Foundation
import KanaKanjiConverterModule

/// Explicit live-OFF prototype of the converter-free input side; not the default bridge.
@MainActor
struct DesktopReadingSession {
    enum Failure: String, Error {
        case unsupportedAction = "unsupported_reading_action"
        case reconversionRequiresCoordinator = "reconversion_requires_coordinator"
    }

    private(set) var composition = CompositionState()
    private var state: InputState = .none
    private var language: InputLanguage = .japanese
    private var generation = 0
    private var compositionRevision = 0
    private var candidates = DesktopReadingCandidates()
    private var candidateContext: DesktopReadingCandidateContext?
    private var candidateCompletions: [DesktopCandidateCompletion] = []
    private let japaneseInputStyle: InputStyle

    init(inputStyle: InputStyle = .mapped(id: .defaultRomanToKana)) {
        japaneseInputStyle = inputStyle
    }

    private var inputStyle: InputStyle {
        language == .english ? .direct : japaneseInputStyle
    }

    mutating func key(_ event: KeyEventCore, doubleTap: Bool = false) throws -> DesktopSnapshot {
        guard ReconversionShortcut.resolve(event) == nil else {
            throw Failure.reconversionRequiresCoordinator
        }
        guard !doubleTap || event.keyCode != 102 || composition.isEmpty else {
            throw Failure.unsupportedAction
        }
        // Unsupported actions must leave the entire formal state available for the coordinator.
        var next = self
        next.candidateCompletions = []
        let previous = try candidateContext.map { _ in try CompositionSnapshot.capture(composition).encoded() }
        var response = try next.applyKey(event)
        if let previous, try CompositionSnapshot.capture(next.composition).encoded() != previous {
            next.compositionRevision += 1
            next.candidates.invalidate()
            next.candidateContext = next.candidateContext.map { next.currentContext($0) }
        } else if previous == nil {
            // No candidate request exists yet; advancing conservatively cannot invalidate a selection.
            next.compositionRevision += 1
        }
        if next.composition.isEmpty {
            next.candidateContext = nil
        } else if !response.commits.isEmpty, let context = next.candidateContext {
            let left = DesktopReadingSurroundings.appending(response.commits, to: context.leftContext)
            next.candidateContext = next.currentContext(context, leftContext: left)
        }
        response.compositionRevision = next.compositionRevision
        response.candidateCompletions = next.candidateCompletions.isEmpty ? nil : next.candidateCompletions
        self = next
        return response
    }

    mutating func reset(commit: Bool) throws -> DesktopSnapshot {
        var next = self
        next.candidateCompletions = []
        let commits = commit ? [try next.commitDisplayedText()] : []
        next.composition.stopComposition()
        next.candidates.invalidate()
        next.candidateContext = nil
        next.state = .none
        next.generation += 1
        next.compositionRevision += 1
        var response = next.snapshot(commits: commits)
        response.candidateCompletions = next.candidateCompletions.isEmpty ? nil : next.candidateCompletions
        self = next
        return response
    }

    mutating func prepareCandidates(context: DesktopReadingCandidateContext) throws -> DesktopCandidateRequest {
        let current = currentContext(context)
        if let candidateContext, candidateContext != current {
            throw DesktopReadingCandidates.Failure.staleRequest
        }
        let request = try candidates.prepare(composition: composition, context: current)
        candidateContext = current
        return request
    }

    mutating func adoptCandidates(_ batch: DesktopCandidateBatch) throws -> DesktopCandidateBatchReference {
        guard let candidateContext else { throw DesktopReadingCandidates.Failure.staleRequest }
        return try candidates.adopt(batch, composition: composition, context: currentContext(candidateContext))
    }

    mutating func selectCandidate(_ selection: DesktopCandidateSelection) throws -> DesktopSnapshot {
        guard let candidateContext else { throw DesktopReadingCandidates.Failure.unavailableCandidate }
        try candidates.select(selection, composition: composition, context: currentContext(candidateContext))
        state = .selecting
        generation += 1
        return snapshot()
    }

    /// Only immediate keyboard navigation may translate a current list position into an identity.
    mutating func selectCurrentCandidate(index: Int) throws -> DesktopSnapshot {
        guard let batch = candidates.batch, batch.candidates.indices.contains(index) else {
            throw DesktopReadingCandidates.Failure.unavailableCandidate
        }
        let selection = DesktopCandidateSelection(
            batch: .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID),
            candidateID: batch.candidates[index].candidateID)
        return try selectCandidate(selection)
    }

    mutating func candidateWorkerUnavailable() {
        candidates.workerUnavailable()
    }

    mutating func updateLearningRevision(_ revision: Int) throws {
        guard revision >= 0 else { throw DesktopReadingCandidates.Failure.changedSettings }
        // A global learning change also reaches contexts that have not requested candidates yet.
        guard let candidateContext else {
            return
        }
        try candidates.updateLearningRevision(from: candidateContext.settingsRevision, to: revision)
        var current = candidateContext
        current.settingsRevision = revision
        self.candidateContext = current
    }

    private func currentContext(
        _ context: DesktopReadingCandidateContext, leftContext: String? = nil
    ) -> DesktopReadingCandidateContext {
        .init(context: context.context, readingProcessGeneration: context.readingProcessGeneration,
              focusEpoch: context.focusEpoch, compositionRevision: compositionRevision,
              settingsRevision: context.settingsRevision, leftContext: leftContext ?? context.leftContext,
              rightContext: context.rightContext, privateInput: context.privateInput)
    }

    func snapshot(commits: [String] = []) -> DesktopSnapshot {
        var response = DesktopSnapshot()
        response.commits = commits.filter { !$0.isEmpty }
        response.generation = generation
        response.compositionRevision = compositionRevision
        response.language = language == .japanese ? "japanese" : "english"
        response.reading = composition.convertTarget
        response.readingCursor = unicodeScalarOffset(in: response.reading, utf16Offset: composition.readingCursorUTF16Offset)
        response.inputState = state.bridgeName
        switch state {
        case .unicodeInput(let codePoint):
            response.preedit = "U+" + codePoint
            response.cursor = response.preedit.unicodeScalars.count
        case .composing:
            response.preedit = response.reading
            response.cursor = response.readingCursor
        case .previewing, .selecting:
            if let text = candidates.selectedText, let suffix = candidates.selectedSuffix {
                response.preedit = text + suffix
                response.cursor = text.unicodeScalars.count
                response.selection = candidates.selectionIndex
            } else {
                response.preedit = response.reading
                response.cursor = response.readingCursor
            }
        default:
            break
        }
        return response
    }

    // Match Core's key interpretation; candidate-dependent actions stay explicit until connected.
    // swiftlint:disable:next cyclomatic_complexity
    private mutating func applyKey(_ event: KeyEventCore) throws -> DesktopSnapshot {
        generation += 1
        if Config.OptionDirectFullWidthInput().value,
           let text = OptionDirectInputResolver.resolve(characters: event.characters, modifierFlags: event.modifierFlags,
                                                       inputLanguage: language, inputState: state, typeBackSlash: Config.TypeBackSlash().value) {
            return snapshot(commits: [text])
        }
        let action = UserAction.getUserAction(eventCore: event, inputLanguage: language)
        switch action {
        case .suggest, .transformSelectedText:
            throw Failure.unsupportedAction
        default:
            break
        }
        let (clientAction, callback) = state.event(
            eventCore: event, userAction: action, inputLanguage: language,
            liveConversionEnabled: false, enableDebugWindow: false, enableSuggestion: false)
        var commits: [String] = []
        var consumed = true
        switch clientAction {
        case .consume:
            break
        case .fallthrough:
            consumed = false
        case .appendToMarkedText(let text):
            composition.insertAtCursorPosition(text, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces):
            composition.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let text):
            commits.append(text)
        case .removeLastMarkedText:
            candidates.clearSelection()
            composition.deleteBackwardFromCursorPosition()
        case .removeNextMarkedText:
            candidates.clearSelection()
            composition.deleteForwardFromCursorPosition()
        case .moveCompositionCursor(let movement):
            candidates.clearSelection()
            composition.moveCursor(movement)
        case .commitMarkedText:
            commits.append(try commitDisplayedText())
        case .submitSelectedCandidate:
            guard let candidateContext else { throw Failure.unsupportedAction }
            let committed = try candidates.takeSelection(composition: composition, context: currentContext(candidateContext))
            commits.append(committed.text)
            composition = committed.remaining
            candidateCompletions.append(committed.completion)
        case .stopComposition:
            composition.stopComposition()
        case .selectInputLanguage(let selectedLanguage):
            language = selectedLanguage
        case .commitMarkedTextAndSelectInputLanguage(let selectedLanguage):
            commits.append(try commitDisplayedText())
            language = selectedLanguage
            state = .none
        case .submitUnicodeInput(let codePoint):
            if let value = UInt32(codePoint, radix: 16), let scalar = Unicode.Scalar(value) {
                commits.append(String(scalar))
            }
        case .enterUnicodeInputMode, .appendToUnicodeInput, .removeLastUnicodeInput, .cancelUnicodeInput:
            break
        default:
            throw Failure.unsupportedAction
        }
        if consumed {
            applyCallback(callback)
        }
        var response = snapshot(commits: commits)
        response.consumed = consumed
        return response
    }

    private mutating func commitDisplayedText() throws -> String {
        guard !composition.isEmpty else {
            return ""
        }
        let text: String
        if candidates.selectedText != nil {
            guard let candidateContext else { throw DesktopReadingCandidates.Failure.unavailableCandidate }
            let selected = try candidates.takeSelection(composition: composition, context: currentContext(candidateContext))
            text = selected.text + selected.remaining.convertTarget
            // A selected prefix plus a raw suffix is not a synthetic candidate to learn.
            if selected.remaining.isEmpty { candidateCompletions.append(selected.completion) }
        } else {
            text = composition.convertTarget
        }
        composition.stopComposition()
        candidates.invalidate()
        return text
    }

    private mutating func applyCallback(_ callback: ClientActionCallback) {
        switch callback {
        case .fallthrough:
            break
        case .transition(let next):
            state = next
        case .basedOnBackspace(let empty, let nonempty), .basedOnSubmitCandidate(let empty, let nonempty):
            state = composition.isEmpty ? empty : nonempty
        }
    }
}
