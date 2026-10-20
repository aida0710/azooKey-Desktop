import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModule

extension azooKeyMacInputController {
    @MainActor
    func requestReconversion(undo: Bool, reading: String? = nil, client: IMKTextInput) {
        do {
            guard segmentsManager.isEmpty, inputState == .none else {
                throw ReconversionSession.Failure.compositionActive
            }
            let replacement = try reconversionClient.prepare(undo: undo, client: client, reading: reading)
            try reconversionClient.apply(replacement, client: client, manager: segmentsManager)
            cancelReplaceSuggestion()
            inputState = .selecting
            reconversionStatusPanel.orderOut(nil)
            refreshMarkedText()
            refreshCandidateWindow()
            refreshPredictionWindow()
        } catch ReconversionSession.Failure.readingRequired {
            do {
                try reconversionClient.beginReading(client: client)
                showReconversionReading()
            } catch {
                showReconversionFailure(.replacementUnavailable)
            }
        } catch let failure as ReconversionSession.Failure {
            showReconversionFailure(failure)
        } catch {
            showReconversionFailure(.replacementUnavailable)
        }
    }

    @MainActor
    func handleReconversionReading(_ event: KeyEventCore, client: IMKTextInput) -> Bool {
        guard reconversionClient.readingRequest != nil else {
            return false
        }
        guard reconversionClient.readingContextIsCurrent(client: client) else {
            reconversionClient.readingRequest = nil
            showReconversionFailure(.changedContext)
            return true
        }
        switch UserAction.getUserAction(eventCore: event, inputLanguage: .japanese) {
        case .input(let pieces):
            reconversionClient.readingRequest?.input.insertAtCursorPosition(pieces: pieces, inputStyle: .mapped(id: .defaultRomanToKana))
        case .backspace:
            reconversionClient.readingRequest?.input.deleteBackwardFromCursorPosition(count: 1)
        case .enter:
            let reading = reconversionClient.readingRequest?.input.convertTarget
            reconversionClient.readingRequest = nil
            requestReconversion(undo: false, reading: reading, client: client)
            return true
        case .escape:
            reconversionClient.readingRequest = nil
            reconversionStatusPanel.orderOut(nil)
            return true
        default:
            return true
        }
        showReconversionReading()
        return true
    }

    @MainActor
    private func showReconversionReading() {
        let reading = reconversionClient.readingRequest?.input.convertTarget ?? ""
        let message = String(format: Localization.text("reconversion.reading_input"), reading)
        reconversionStatusPanel.show(message: message, cursorLocation: getCursorLocation())
    }

    @MainActor
    func showReconversionFailure(_ failure: ReconversionSession.Failure) {
        reconversionStatusPanel.show(key: "reconversion.\(failure.rawValue)", cursorLocation: getCursorLocation())
    }

    @MainActor @objc func undoLastCommit(_ sender: Any) {
        guard let client = client() else {
            return
        }
        requestReconversion(undo: true, client: client)
    }

    @MainActor @objc func reconvertSelection(_ sender: Any) {
        guard let client = client() else {
            return
        }
        requestReconversion(undo: false, client: client)
    }
}
