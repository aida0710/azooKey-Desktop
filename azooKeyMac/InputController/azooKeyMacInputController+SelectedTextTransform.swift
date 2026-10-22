import Cocoa
import Core
import Foundation
import InputMethodKit

// MARK: - Selected Text Transform Methods
extension azooKeyMacInputController {

    struct TextContext {
        let before: String
        let selected: String
        let after: String
    }

    @MainActor
    func getContextAroundSelection(client: IMKTextInput, selectedRange: NSRange, contextLength: Int = AIRequestScope.contextCharacterLimit) -> TextContext {
        // Get the selected text
        var actualRange = NSRange()
        let selectedText = client.string(from: selectedRange, actualRange: &actualRange) ?? ""

        // Calculate context ranges
        let documentLength = client.length()

        // Get text before selection (up to contextLength characters)
        let beforeStart = max(0, selectedRange.location - contextLength)
        let beforeLength = selectedRange.location - beforeStart
        let beforeRange = NSRange(location: beforeStart, length: beforeLength)

        // Get text after selection (up to contextLength characters)
        let afterStart = selectedRange.location + selectedRange.length
        let afterLength = max(0, min(contextLength, documentLength - afterStart))
        let afterRange = NSRange(location: afterStart, length: afterLength)

        // Extract context strings
        var beforeActualRange = NSRange()
        let beforeText = (beforeLength > 0) ? (client.string(from: beforeRange, actualRange: &beforeActualRange) ?? "") : ""

        var afterActualRange = NSRange()
        let afterText = (afterLength > 0) ? (client.string(from: afterRange, actualRange: &afterActualRange) ?? "") : ""

        return TextContext(before: beforeText, selected: selectedText, after: afterText)
    }

    @MainActor
    func showPromptInputWindow(initialPrompt: String? = nil) {
        self.appendDebugMessage("showPromptInputWindow: Starting")
        guard let requestConfiguration = AIRequestConfiguration.current() else {
            return
        }
        self.cancelReplaceSuggestion()

        // Set flag to prevent recursive calls
        self.isPromptWindowVisible = true

        // Get selected text
        guard let client = self.client(), let currentApp = NSWorkspace.shared.frontmostApplication else {
            self.appendDebugMessage("showPromptInputWindow: No client available")
            self.isPromptWindowVisible = false
            return
        }

        let application = MacSelectedTextTransformSession.Application(
            restoreFocus: { currentApp.activate(options: []) }, isActive: { currentApp.isActive }
        )
        let session = MacSelectedTextTransformSession.shared
        if let previous = self.selectedTextTransformTarget { session.cancel(target: previous) }
        self.selectedTextTransformTarget = nil
        let source = MacSelectedTextClient(client: client, focus: session, applicationIsActive: application.isActive)
        guard let target = try? SelectedTextReplacement(client: source) else {
            self.appendDebugMessage("showPromptInputWindow: Selection could not be verified")
            self.isPromptWindowVisible = false
            return
        }
        self.selectedTextTransformTarget = target
        let storedSelectedRange = target.range
        let selectedText = target.text

        // Get cursor position for window placement
        var cursorLocation = NSPoint.zero
        var rect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        cursorLocation = rect.origin

        self.appendDebugMessage("showPromptInputWindow: Cursor location: \(cursorLocation)")

        // Show prompt input window with preview functionality
        self.promptInputWindow.showPromptInput(
            at: cursorLocation,
            request: PromptInputRequest(
                initialPrompt: initialPrompt, configuration: requestConfiguration, targetText: selectedText
            ),
            onPreview: { [weak self] prompt, includeContext, callback in
                guard let self = self else {
                    return
                }
                self.appendDebugMessage("showPromptInputWindow: Preview requested")

                Task {
                    do {
                        guard target.matchesDocument(in: source) else {
                            callback(.failure(.targetChanged))
                            return
                        }
                        let context = includeContext
                            ? self.getContextAroundSelection(client: client, selectedRange: storedSelectedRange)
                            : TextContext(before: "", selected: selectedText, after: "")
                        let scope = AIRequestScope(
                            target: selectedText, before: context.before, after: context.after, includeContext: includeContext
                        )
                        let result = try await self.requestTransformationPreview(
                            scope: scope, prompt: prompt, configuration: requestConfiguration
                        )
                        callback(.success(result))
                    } catch {
                        await MainActor.run {
                            self.appendDebugMessage("showPromptInputWindow: Preview failed")
                        }
                        // Endpoint errors can include URL credentials. Keep
                        // the preview message free of backend-provided text.
                        callback(.failure((error as? TransformationPreviewError) ?? .requestFailed))
                    }
                }
            },
            onApply: { [weak self] transformedText in
                self?.applySelectedTextTransform(transformedText, target: target, application: application)
            },
            completion: { [weak self] prompt in
                self?.appendDebugMessage("showPromptInputWindow: Window closed")
                self?.isPromptWindowVisible = false

                if prompt == nil {
                    session.cancel(target: target)
                    if self?.selectedTextTransformTarget === target {
                        self?.selectedTextTransformTarget = nil
                    }
                }
                // 設定変更に備えてキャッシュを更新
                self?.reloadPinnedPromptsCache()
            }
        )
    }

    @MainActor
    private func applySelectedTextTransform(
        _ text: String, target: SelectedTextReplacement, application: MacSelectedTextTransformSession.Application
    ) {
        guard self.selectedTextTransformTarget === target else {
            return
        }
        MacSelectedTextTransformSession.shared.apply(target: target, text: text, application: application) { [weak self] applied in
            guard let self, self.selectedTextTransformTarget === target else {
                return
            }
            self.selectedTextTransformTarget = nil
            if !applied { self.showSelectedTextReplacementFailure(text) }
        }
    }

    @MainActor
    func triggerAiTranslation(initialPrompt: String) -> Bool {
        let aiBackendEnabled = Config.AIBackendPreference().value != .off
        guard aiBackendEnabled else {
            self.appendDebugMessage("AI translation ignored: AI backend is off")
            return false
        }
        if self.isPromptWindowVisible {
            self.appendDebugMessage("AI translation ignored: prompt window already visible")
            return true
        }
        guard self.client() != nil else {
            self.appendDebugMessage("AI translation ignored: No client available")
            return false
        }
        self.showPromptInputWindow(initialPrompt: initialPrompt)
        return true
    }

    @MainActor
    func transformSelectedText(selectedText: String, prompt: String) {
        guard let client = self.client() else {
            return
        }
        var actualRange = NSRange()
        guard client.string(from: client.selectedRange(), actualRange: &actualRange) == selectedText else {
            return
        }
        showPromptInputWindow(initialPrompt: prompt)
    }

    @MainActor
    private func showSelectedTextReplacementFailure(_ transformedText: String) {
        let alert = NSAlert()
        alert.messageText = Localization.text("ai.preview.target-changed")
        alert.addButton(withTitle: Localization.text("ai.preview.copy"))
        alert.addButton(withTitle: Localization.text("ai.scope.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transformedText, forType: .string)
        }
    }

    func requestTransformationPreview(
        scope: AIRequestScope, prompt: String, configuration: AIRequestConfiguration
    ) async throws -> String {
        if configuration.backend == .openAI, configuration.apiKey.isEmpty {
            throw TransformationPreviewError.missingAPIKey
        }
        return try await AIClient.sendTextTransformRequest(
            scope.transformationPrompt(instructions: prompt),
            backend: configuration.backend,
            modelName: configuration.modelName,
            apiKey: configuration.apiKey,
            apiEndpoint: configuration.apiEndpoint
        )
    }
}
