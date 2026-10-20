import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

extension azooKeyMacInputController {
    @MainActor
    @discardableResult
    func requestReplaceSuggestion() -> Task<Void, Never>? {
        if aiSuggestionConfirmation != nil {
            return nil
        }
        cancelReplaceSuggestion()
        inputState = segmentsManager.isEmpty ? .none : .composing
        guard !segmentsManager.isEmpty, let client = self.client(),
              let configuration = AIRequestConfiguration.current() else {
            return nil
        }

        // Repeating a request restores the original reading before capturing
        // the client's selection; the previous AI candidate can be longer.
        refreshMarkedText()
        let confirmation = AISuggestionConfirmation(
            reading: segmentsManager.convertTarget,
            clientIdentity: ObjectIdentifier(client), selectedRange: client.selectedRange(),
            configuration: configuration, includeContext: Config.IncludeContextInAITransform().value
        )
        aiSuggestionConfirmation = confirmation
        aiSuggestionConfirmationPanel.onSend = { [weak self] in self?.confirmReplaceSuggestion() }
        aiSuggestionConfirmationPanel.onCancel = { [weak self] in self?.cancelReplaceSuggestion() }
        aiSuggestionConfirmationPanel.onContextChanged = { [weak self] in self?.setSuggestionContextIncluded($0) }
        aiSuggestionConfirmationPanel.show(
            configuration: configuration, reading: confirmation.reading,
            includeContext: confirmation.includeContext, cursorLocation: getCursorLocation()
        )
        return nil
    }

    @MainActor
    func setSuggestionContextIncluded(_ value: Bool) {
        aiSuggestionConfirmation?.includeContext = value
        Config.IncludeContextInAITransform().value = value
        aiSuggestionConfirmationPanel.setIncludesContext(value)
    }

    @MainActor
    func handleAISuggestionConfirmationKey(_ event: NSEvent) -> Bool? {
        guard let confirmation = aiSuggestionConfirmation else {
            return nil
        }
        let modifiers = event.keyEventCore.modifierFlags
        if event.charactersIgnoringModifiers == "\u{1b}", modifiers.isEmpty {
            cancelReplaceSuggestion()
            return true
        }
        guard event.charactersIgnoringModifiers?.lowercased() == "s" else {
            return nil
        }
        if modifiers == [.control, .shift] {
            setSuggestionContextIncluded(!confirmation.includeContext)
            return true
        }
        if modifiers == [.control] {
            confirmReplaceSuggestion()
            return true
        }
        return nil
    }

    @MainActor
    @discardableResult
    func confirmReplaceSuggestion() -> Task<Void, Never>? {
        guard let confirmation = aiSuggestionConfirmation,
              let client = self.client(),
              ObjectIdentifier(client) == confirmation.clientIdentity,
              client.selectedRange() == confirmation.selectedRange,
              segmentsManager.convertTarget == confirmation.reading else {
            cancelReplaceSuggestion()
            return nil
        }
        aiSuggestionConfirmation = nil
        aiSuggestionConfirmationPanel.orderOut(nil)
        let scope = AIRequestScope(
            target: confirmation.reading,
            before: confirmation.includeContext ? getLeftSideContext(maxCount: AIRequestScope.contextCharacterLimit) ?? "" : "",
            after: confirmation.includeContext ? getRightSideContext(maxCount: AIRequestScope.contextCharacterLimit) ?? "" : "",
            includeContext: confirmation.includeContext
        )
        aiSuggestionStatusPanel.show(key: "ai.suggestion.loading", cursorLocation: getCursorLocation())
        let request = confirmation.configuration.suggestionRequest(scope: scope)
        return aiSuggestionSession.request(request) { [weak self] completion in
            guard let self else {
                return
            }
            guard self.inputState == .composing,
                  self.segmentsManager.convertTarget == confirmation.reading,
                  let currentClient = self.client(),
                  ObjectIdentifier(currentClient) == confirmation.clientIdentity,
                  currentClient.selectedRange() == confirmation.selectedRange else {
                self.cancelReplaceSuggestion()
                return
            }
            switch completion {
            case .candidates:
                self.showReplaceSuggestions(reading: confirmation.reading)
            case .empty:
                self.aiSuggestionStatusPanel.show(key: "ai.suggestion.empty", cursorLocation: self.getCursorLocation())
            case .failed:
                self.aiSuggestionStatusPanel.show(key: "ai.suggestion.failed", cursorLocation: self.getCursorLocation())
            }
        }
    }

    @MainActor
    private func showReplaceSuggestions(reading: String) {
        let candidates = aiSuggestionSession.suggestions.map {
            Candidate(text: $0, value: 0, composingCount: .surfaceCount(reading.count), lastMid: 0, data: [])
        }
        segmentsManager.setReplaceSuggestions(candidates)
        segmentsManager.requestSelectingSuggestionRow(0)
        inputState = .replaceSuggestion
        replaceSuggestionsViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) }, selectionIndex: 0, cursorLocation: getCursorLocation()
        )
        aiSuggestionStatusPanel.orderOut(nil)
        replaceSuggestionWindow.orderFront(nil)
        refreshMarkedText()
        refreshCandidateWindow()
        refreshPredictionWindow()
    }

    @MainActor
    func clearReplaceSuggestionCandidates() {
        segmentsManager.setReplaceSuggestions([])
        replaceSuggestionsViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        replaceSuggestionWindow.orderOut(nil)
    }

    @MainActor
    func cancelReplaceSuggestion() {
        aiSuggestionConfirmation = nil
        aiSuggestionConfirmationPanel.orderOut(nil)
        aiSuggestionSession.cancel()
        aiSuggestionStatusPanel.orderOut(nil)
        clearReplaceSuggestionCandidates()
    }

    @MainActor
    func hideReplaceSuggestionCandidateView() {
        cancelReplaceSuggestion()
    }

    @MainActor
    func submitSelectedSuggestionCandidate(client: IMKTextInput) {
        let text: String
        if inputState == .replaceSuggestion, let suggestion = aiSuggestionSession.selectedSuggestion {
            text = suggestion
            segmentsManager.stopComposition()
        } else {
            // An empty or cleared view must never discard the original input.
            text = segmentsManager.commitMarkedText(inputState: .composing)
        }
        if !text.isEmpty {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        cancelReplaceSuggestion()
        inputState = .none
        refreshMarkedText()
        refreshCandidateWindow()
        refreshPredictionWindow()
    }
}
