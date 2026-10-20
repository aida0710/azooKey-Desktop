import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

extension azooKeyMacInputController {
    // Match the desktop bridge's context limit.
    private static let aiSuggestionContextLength = 100

    @MainActor
    @discardableResult
    func requestReplaceSuggestion() -> Task<Void, Never>? {
        cancelReplaceSuggestion()
        inputState = segmentsManager.isEmpty ? .none : .composing
        guard !segmentsManager.isEmpty, let client = self.client() else {
            return nil
        }
        let backend: AIBackend
        switch Config.AIBackendPreference().value {
        case .off: return nil
        case .foundationModels: backend = .foundationModels
        case .openAI: backend = .openAI
        }

        // Repeating a request restores the original reading before capturing
        // the client's selection; the previous AI candidate can be longer.
        refreshMarkedText()
        let reading = segmentsManager.convertTarget
        let clientIdentity = ObjectIdentifier(client)
        let selectedRange = client.selectedRange()
        let prompt: String
        if Config.IncludeContextInAITransform().value {
            let before = getLeftSideContext(maxCount: Self.aiSuggestionContextLength) ?? ""
            let after = getRightSideContext(maxCount: Self.aiSuggestionContextLength) ?? ""
            prompt = [
                before.isEmpty ? nil : "Text before: ...\(before)",
                after.isEmpty ? nil : "Text after: \(after)..."
            ].compactMap(\.self).joined(separator: "\n")
        } else {
            prompt = ""
        }
        let model = Config.OpenAiModelName().value
        let endpoint = Config.OpenAiApiEndpoint().value
        let request = AISuggestionRequest(
            conversion: OpenAIRequest(
                prompt: prompt, target: reading,
                modelName: model.isEmpty ? Config.OpenAiModelName.default : model
            ),
            backend: backend,
            apiKey: Config.OpenAiApiKey().value,
            apiEndpoint: endpoint.isEmpty ? Config.OpenAiApiEndpoint.default : endpoint
        )
        aiSuggestionStatusPanel.show(key: "ai.suggestion.loading", cursorLocation: getCursorLocation())
        return aiSuggestionSession.request(request) { [weak self] completion in
            guard let self else {
                return
            }
            guard self.inputState == .composing,
                  self.segmentsManager.convertTarget == reading,
                  let currentClient = self.client(),
                  ObjectIdentifier(currentClient) == clientIdentity,
                  currentClient.selectedRange() == selectedRange else {
                self.cancelReplaceSuggestion()
                return
            }
            switch completion {
            case .candidates:
                self.showReplaceSuggestions(reading: reading)
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
