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
        // The surrounding text is read now so that sending uses what was reviewed.
        let surrounding = (
            before: getLeftSideContext(maxCount: AIRequestScope.contextCharacterLimit) ?? "",
            after: getRightSideContext(maxCount: AIRequestScope.contextCharacterLimit) ?? ""
        )
        let confirmation = AISuggestionConfirmation(
            reading: segmentsManager.convertTarget, surrounding: surrounding,
            clientIdentity: ObjectIdentifier(client), selectedRange: client.selectedRange(), configuration: configuration
        )
        aiSuggestionConfirmation = confirmation
        aiSuggestionConfirmationPanel.onSend = { [weak self] in self?.confirmReplaceSuggestion() }
        aiSuggestionConfirmationPanel.onCancel = { [weak self] in self?.cancelReplaceSuggestion() }
        aiSuggestionConfirmationPanel.onContextChanged = { [weak self] in self?.setSuggestionContextIncluded($0) }
        aiSuggestionConfirmationPanel.show(
            configuration: configuration, reading: confirmation.review.content.target,
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
        // Other keys close the review through ordinary input.
        switch DesktopKeyBinding.command(for: event.keyEventCore, in: AISuggestionReview.keyBindings) {
        case .send?:
            confirmReplaceSuggestion()
        case .toggleContext?:
            setSuggestionContextIncluded(!confirmation.includeContext)
        case .cancel?:
            cancelReplaceSuggestion()
        case .suggestion?, .unicode?, .prompt?, nil:
            return nil
        }
        return true
    }

    @MainActor
    @discardableResult
    func confirmReplaceSuggestion() -> Task<Void, Never>? {
        guard let confirmation = aiSuggestionConfirmation,
              let client = self.client(),
              ObjectIdentifier(client) == confirmation.clientIdentity,
              client.selectedRange() == confirmation.selectedRange,
              confirmation.isCurrent(reading: segmentsManager.convertTarget) else {
            cancelReplaceSuggestion()
            return nil
        }
        aiSuggestionConfirmation = nil
        aiSuggestionConfirmationPanel.orderOut(nil)
        aiSuggestionStatusPanel.show(key: "ai.suggestion.loading", cursorLocation: getCursorLocation())
        return aiSuggestionSession.request(confirmation.suggestionRequest()) { [weak self] completion in
            guard let self else {
                return
            }
            guard self.inputState == .composing,
                  confirmation.isCurrent(reading: self.segmentsManager.convertTarget),
                  let currentClient = self.client(),
                  ObjectIdentifier(currentClient) == confirmation.clientIdentity,
                  currentClient.selectedRange() == confirmation.selectedRange else {
                self.cancelReplaceSuggestion()
                return
            }
            switch completion {
            case .candidates:
                self.showReplaceSuggestions(reading: confirmation.review.reading)
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
            candidates.map { .init(candidate: $0) }, selectionIndex: 0, cursorLocation: getCursorLocation(),
            enterConfirmsCandidate: inputState.enterConfirmsCandidate
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
        replaceSuggestionsViewController.updateCandidatePresentations(
            [], selectionIndex: nil, cursorLocation: .zero, enterConfirmsCandidate: false
        )
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
            reconversionClient.commitText(text, client: client)
        }
        cancelReplaceSuggestion()
        inputState = .none
        refreshMarkedText()
        refreshCandidateWindow()
        refreshPredictionWindow()
    }
}
