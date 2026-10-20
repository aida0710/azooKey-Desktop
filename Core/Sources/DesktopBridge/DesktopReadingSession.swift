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
    // A pending preview/selection keeps the visible reading until another explicit input.
    private var pendingConversionState: InputState?
    private var japaneseInputStyle: InputStyle
    private let candidateRequestMode: DesktopCandidateRequestMode
    private var customInputTableRevisions: [String: String] = [:]

    init(inputStyle: InputStyle = .mapped(id: .defaultRomanToKana), candidateRequestMode: DesktopCandidateRequestMode = .manual) {
        japaneseInputStyle = inputStyle
        self.candidateRequestMode = candidateRequestMode
    }

    var canConfigureSettings: Bool { composition.isEmpty && state == .none }

    mutating func configureSettings(_ runtime: DesktopWorkerSettingsRuntime) {
        japaneseInputStyle = runtime.inputStyle
        customInputTableRevisions = runtime.customInputTableRevisions
        candidates = .init(customInputTableRevisions: runtime.customInputTableRevisions)
        candidateContext = nil
        candidateCompletions = []
        pendingConversionState = nil
    }

    func compositionSnapshot() throws -> CompositionSnapshot {
        try .capture(composition, registeredCustomTables: customInputTableRevisions)
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
        let previous = try candidateContext.map { _ in try compositionSnapshot().encoded() }
        var response = try next.applyKey(event)
        if let previous, try next.compositionSnapshot().encoded() != previous {
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
        next.pendingConversionState = nil
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
        pendingConversionState = nil
        state = .selecting
        generation += 1
        return snapshot()
    }

    /// Only immediate keyboard navigation may translate a current list position into an identity.
    mutating func selectCurrentCandidate(index: Int) throws -> DesktopSnapshot {
        try selectCandidate(at: index)
        pendingConversionState = nil
        state = .selecting
        generation += 1
        return snapshot()
    }

    private mutating func selectCandidate(at index: Int) throws {
        guard let batch = candidates.batch, batch.candidates.indices.contains(index) else {
            throw DesktopReadingCandidates.Failure.unavailableCandidate
        }
        guard let candidateContext else { throw DesktopReadingCandidates.Failure.unavailableCandidate }
        let selection = DesktopCandidateSelection(
            batch: .init(authority: batch.authority, workerGeneration: batch.workerGeneration, batchID: batch.batchID),
            candidateID: batch.candidates[index].candidateID)
        try candidates.select(selection, composition: composition, context: currentContext(candidateContext))
    }

    mutating func candidateWorkerUnavailable() {
        candidates.workerUnavailable()
    }

    func candidateView() throws -> DesktopCandidateView? {
        try candidates.view(options: .init(showRelativeScores: Config.ShowRelativeScores().value,
                                           showCandidateIndex: state == .selecting))
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
        response.showCandidateIndex = state == .selecting && candidates.batch != nil
        response.pageStart = (candidates.selectionIndex ?? 0) / CandidatePage.size * CandidatePage.size
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

    // Core interprets the key; the reading owner decides when an available candidate is selected.
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
        let prefetch = candidateRequestMode.requestsCandidates(after: clientAction)
        let previousComposition = prefetch ? try compositionSnapshot().encoded() : nil
        if let conversion = FunctionKeyConversion(action: clientAction) {
            return try commitConvertedText(conversion)
        }
        var commits: [String] = []
        var consumed = true
        switch clientAction {
        case .consume:
            break
        case .fallthrough:
            consumed = false
        case .appendToMarkedText(let text):
            resumeReading()
            composition.insertAtCursorPosition(text, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces):
            resumeReading()
            composition.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .commitMarkedTextAndAppendToMarkedText(let text):
            commits.append(try commitDisplayedText())
            composition.insertAtCursorPosition(text, inputStyle: inputStyle)
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            commits.append(try commitDisplayedText())
            composition.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let text):
            commits.append(text)
        case .removeLastMarkedText:
            resumeReading()
            composition.deleteBackwardFromCursorPosition()
        case .removeNextMarkedText:
            resumeReading()
            composition.deleteForwardFromCursorPosition()
        case .moveCompositionCursor(let movement):
            resumeReading()
            composition.moveCursor(movement)
        case .commitMarkedText:
            commits.append(try commitDisplayedText())
        case .submitSelectedCandidate:
            return try commitSelectedCandidate(callback: callback)
        case .enterFirstCandidatePreviewMode:
            return try beginConversion(state: .previewing)
        case .enterCandidateSelectionMode:
            return try beginConversion(state: .selecting)
        case .editSegment(let count):
            composition.editSegment(count: count, selectedCount: candidates.selectedCount?.composingCount)
            return requestConversion(state: .selecting)
        case .selectNextCandidate:
            try moveCandidateSelection(by: 1)
        case .selectPrevCandidate:
            try moveCandidateSelection(by: -1)
        case .selectNumberCandidate(let number):
            guard let selectedIndex = candidates.selectionIndex, let batch = candidates.batch else {
                throw DesktopReadingCandidates.Failure.unavailableCandidate
            }
            let index = selectedIndex / CandidatePage.size * CandidatePage.size + number - 1
            guard batch.candidates.indices.contains(index) else {
                return snapshot()
            }
            try selectCandidate(at: index)
            return try commitSelectedCandidate(callback: callback)
        case .hideCandidateWindow:
            cancelConversion()
        case .stopComposition:
            if pendingConversionState != nil {
                cancelConversion()
                return snapshot()
            }
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
        if prefetch, !composition.isEmpty, try compositionSnapshot().encoded() != previousComposition {
            response.request = "candidates"
        }
        return response
    }

    private mutating func commitDisplayedText() throws -> String {
        pendingConversionState = nil
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

    private mutating func beginConversion(state requestedState: InputState) throws -> DesktopSnapshot {
        let nextState = pendingConversionState == .selecting ? .selecting : requestedState
        if pendingConversionState == nil {
            let previous = try compositionSnapshot().encoded()
            composition.insertCompositionSeparator(inputStyle: inputStyle)
            if try compositionSnapshot().encoded() != previous {
                candidates.invalidate()
            }
        }
        guard let index = candidates.preferredSelectionIndex else {
            return requestConversion(state: nextState)
        }
        try selectCandidate(at: index)
        pendingConversionState = nil
        state = nextState
        return snapshot()
    }

    private mutating func requestConversion(
        state requestedState: InputState, commits: [String] = []
    ) -> DesktopSnapshot {
        candidates.invalidate()
        pendingConversionState = requestedState
        state = .composing
        var response = snapshot(commits: commits)
        response.request = "candidates"
        return response
    }

    private mutating func commitSelectedCandidate(callback: ClientActionCallback) throws -> DesktopSnapshot {
        guard let candidateContext else { throw DesktopReadingCandidates.Failure.unavailableCandidate }
        let committed = try candidates.takeSelection(composition: composition, context: currentContext(candidateContext))
        composition = committed.remaining
        candidateCompletions.append(committed.completion)
        pendingConversionState = nil
        applyCallback(callback)
        if composition.isEmpty {
            return snapshot(commits: [committed.text])
        }
        // A suffix has no selected identity until its own candidate batch is explicitly selected.
        return requestConversion(state: state, commits: [committed.text])
    }

    private mutating func commitConvertedText(_ conversion: FunctionKeyConversion) throws -> DesktopSnapshot {
        let isSelectingRange = state == .selecting || pendingConversionState == .selecting
        let count = isSelectingRange
            ? candidates.selectedCount?.composingCount ?? .surfaceCount(composition.conversionRangeEnd ?? composition.convertTarget.count)
            : .inputCount(composition.composingText.input.count)
        let source: String
        let consumed: ComposingCount
        if conversion.isRoman {
            (source, consumed) = composition.romanInputForSelection(composingCount: count)
        } else {
            let consumption = try CandidateConsumption(composition: composition, count: .init(count))
            source = isSelectingRange ? candidates.selectedReading ?? consumption.consumedReading : composition.convertTarget
            consumed = count
        }
        let text = conversion.convert(source)
        composition.prefixComplete(composingCount: consumed)
        candidates.invalidate()
        pendingConversionState = nil
        // This transforms the formal input; it is not a selection of a stored conversion candidate.
        if composition.isEmpty {
            state = .none
            return snapshot(commits: [text])
        }
        return requestConversion(state: .selecting, commits: [text])
    }

    private mutating func cancelConversion() {
        pendingConversionState = nil
        candidates.invalidate()
        composition.moveCursor(.end)
        state = .composing
    }

    private mutating func resumeReading() {
        pendingConversionState = nil
        candidates.clearSelection()
        composition.clearConversionRange()
        state = .composing
    }

    private mutating func moveCandidateSelection(by offset: Int) throws {
        guard let batch = candidates.batch, let selectedIndex = candidates.selectionIndex,
              !batch.candidates.isEmpty else {
            throw DesktopReadingCandidates.Failure.unavailableCandidate
        }
        let count = batch.candidates.count
        try selectCandidate(at: (selectedIndex + offset + count) % count)
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
