import Cocoa
import Core
import Foundation
import InputMethodKit

// MARK: - Selected Text Transform Methods
extension azooKeyMacInputController {

    // MARK: - Constants
    private enum Constants {
        static let defaultContextLength = AIRequestScope.contextCharacterLimit
        static let cursorPositionTolerance = 2
        static let replacementVerificationDelay = 0.1
        static let clipboardDelay = 0.05
        static let clipboardRestoreDelay = 0.3
    }

    struct TextContext {
        let before: String
        let selected: String
        let after: String
    }

    @MainActor
    func getContextAroundSelection(client: IMKTextInput, selectedRange: NSRange, contextLength: Int = Constants.defaultContextLength) -> TextContext {
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
        let afterLength = min(contextLength, documentLength - afterStart)
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
        guard let client = self.client() else {
            self.appendDebugMessage("showPromptInputWindow: No client available")
            self.isPromptWindowVisible = false
            return
        }

        let selectedRange = client.selectedRange()
        self.appendDebugMessage("showPromptInputWindow: Selected range in window: \(selectedRange)")

        guard selectedRange.length > 0 else {
            self.appendDebugMessage("showPromptInputWindow: No selected text in window")
            self.isPromptWindowVisible = false
            return
        }

        var actualRange = NSRange()
        guard let selectedText = client.string(from: selectedRange, actualRange: &actualRange) else {
            self.appendDebugMessage("showPromptInputWindow: Failed to get selected text")
            self.isPromptWindowVisible = false
            return
        }

        self.appendDebugMessage("showPromptInputWindow: Storing selected range for later use: \(selectedRange)")

        // Store the selected range and current app info for later use
        let storedSelectedRange = selectedRange
        let currentApp = NSWorkspace.shared.frontmostApplication

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
                        if includeContext {
                            var actualRange = NSRange()
                            guard client.selectedRange() == storedSelectedRange,
                                  client.string(from: storedSelectedRange, actualRange: &actualRange) == selectedText,
                                  actualRange == storedSelectedRange else {
                                callback(.failure(.targetChanged))
                                return
                            }
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
                guard let self = self else {
                    return
                }
                self.appendDebugMessage("showPromptInputWindow: Applying transformed text")

                // Close the window first, then restore focus and replace text
                self.promptInputWindow.close()

                // Restore focus to the original app
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let app = currentApp {
                        app.activate(options: [])
                        self.appendDebugMessage("showPromptInputWindow: Restored focus to original app")
                    }

                    // Replace text after focus is restored
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.replaceSelectedText(with: transformedText, usingRange: storedSelectedRange)
                    }
                }
            },
            completion: { [weak self] prompt in
                self?.appendDebugMessage("showPromptInputWindow: Window closed")
                self?.isPromptWindowVisible = false

                // Restore focus on cancel (prompt == nil) here so every closing path including window-level Esc ends up restoring focus.
                if prompt == nil, let app = currentApp {
                    app.activate(options: [])
                    self?.appendDebugMessage("showPromptInputWindow: Restored focus to original app on cancel")
                }
                // 設定変更に備えてキャッシュを更新
                self?.reloadPinnedPromptsCache()
            }
        )
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
    func replaceSelectedText(with newText: String, usingRange storedRange: NSRange) {
        self.appendDebugMessage("replaceSelectedText: Starting")
        self.appendDebugMessage("replaceSelectedText: Using stored range: \(storedRange)")

        guard let client = self.client() else {
            self.appendDebugMessage("replaceSelectedText: No client available")
            return
        }

        // Check current selection for comparison
        let currentSelectedRange = client.selectedRange()
        self.appendDebugMessage("replaceSelectedText: Current selected range: \(currentSelectedRange)")
        self.appendDebugMessage("replaceSelectedText: Stored range to use: \(storedRange)")

        if storedRange.length > 0 {
            self.appendDebugMessage("replaceSelectedText: Starting text replacement")

            // Simplified approach: Try IMK first, fallback to clipboard if needed
            if !self.replaceTextUsingIMK(newText: newText, storedRange: storedRange) {
                self.replaceTextUsingClipboard(newText: newText, storedRange: storedRange)
            }
        } else {
            self.appendDebugMessage("replaceSelectedText: Stored range has no length")
        }
    }

    // Simplified replacement methods

    @MainActor
    private func replaceTextUsingIMK(newText: String, storedRange: NSRange) -> Bool {
        self.appendDebugMessage("replaceTextUsingIMK: Attempting IMK text replacement")

        guard let client = self.client() else {
            self.appendDebugMessage("replaceTextUsingIMK: No client available")
            return false
        }

        // Try direct replacement using IMK
        client.insertText(newText, replacementRange: storedRange)

        // Verify the replacement worked by checking cursor position
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.replacementVerificationDelay) {
            let currentRange = client.selectedRange()
            let expectedLocation = storedRange.location + newText.count

            if abs(currentRange.location - expectedLocation) <= Constants.cursorPositionTolerance {
                self.appendDebugMessage("replaceTextUsingIMK: IMK replacement appears successful")
            } else {
                self.appendDebugMessage("replaceTextUsingIMK: IMK replacement may have failed")
            }
        }

        return true // Assume success, fallback will handle failures
    }

    @MainActor
    private func replaceTextUsingClipboard(newText: String, storedRange: NSRange) {
        self.appendDebugMessage("replaceTextUsingClipboard: Starting clipboard-based replacement")

        guard let client = self.client() else {
            self.appendDebugMessage("replaceTextUsingClipboard: No client available")
            return
        }

        // Store and set clipboard
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(newText, forType: .string)

        // Set selection and paste
        client.setMarkedText("", selectionRange: storedRange, replacementRange: storedRange)

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clipboardDelay) {
            // Simulate Cmd+V
            if let source = CGEventSource(stateID: .hidSystemState),
               let cmdVDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
               let cmdVUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {

                cmdVDown.flags = .maskCommand
                cmdVUp.flags = .maskCommand
                cmdVDown.post(tap: .cghidEventTap)
                cmdVUp.post(tap: .cghidEventTap)
            }

            // Restore clipboard after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.clipboardRestoreDelay) {
                if let original = originalContent {
                    pasteboard.clearContents()
                    pasteboard.setString(original, forType: .string)
                }
            }
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
