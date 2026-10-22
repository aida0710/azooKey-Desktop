import Cocoa
import Core
import Foundation
import InputMethodKit

// MARK: - Selected Text Transform Methods
extension azooKeyMacInputController {
    // The window shows one transformation at a time and the session keeps the
    // captured target with it, so Core's identifier never has to tell two apart.
    private static let transformationIdentifier = 0

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
        let field = source.aiTextField()
        guard let target = try? SelectedTextReplacement(client: source),
              var transformation = AISelectedTextTransformation(
                id: Self.transformationIdentifier, field: field, configuration: requestConfiguration.desktopConfiguration()
              ) else {
            self.appendDebugMessage("showPromptInputWindow: Selection could not be verified")
            self.isPromptWindowVisible = false
            return
        }
        transformation.attachWitness(source.aiSelectionWitness(), current: source.aiTextField())
        self.selectedTextTransformTarget = target

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
                initialPrompt: initialPrompt, configuration: requestConfiguration,
                transformation: transformation, openedField: field
            ),
            onPreview: { [weak self] arguments, callback in
                self?.appendDebugMessage("showPromptInputWindow: Preview requested")
                Task {
                    do {
                        callback(.success(try await Self.requestTransformationPreview(arguments, configuration: requestConfiguration)))
                    } catch {
                        await MainActor.run {
                            self?.appendDebugMessage("showPromptInputWindow: Preview failed")
                        }
                        // Endpoint errors can include URL credentials. Keep
                        // the preview message free of backend-provided text.
                        callback(.failure((error as? TransformationPreviewError) ?? .requestFailed))
                    }
                }
            },
            onApply: { [weak self] confirmed in
                self?.applySelectedTextTransform(confirmed, target: target, application: application)
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
                // 指示画面で固定やショートカットが変わることがある
                self?.reloadPromptShortcuts()
            }
        )
    }

    @MainActor
    private func applySelectedTextTransform(
        _ confirmed: AISelectedTextTransformation, target: SelectedTextReplacement,
        application: MacSelectedTextTransformSession.Application
    ) {
        guard self.selectedTextTransformTarget === target else {
            return
        }
        let text = confirmed.applicableText ?? ""
        MacSelectedTextTransformSession.shared.apply(
            target: target, transformation: confirmed, application: application
        ) { [weak self] applied in
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

    /// Sends exactly the arguments Core prepared; the platform adds only the
    /// backend and the API key.
    static func requestTransformationPreview(
        _ arguments: AIRequestArguments, configuration: AIRequestConfiguration
    ) async throws -> String {
        if configuration.backend == .openAI, configuration.apiKey.isEmpty {
            throw TransformationPreviewError.missingAPIKey
        }
        return try await arguments.requestTransformation(backend: configuration.backend, apiKey: configuration.apiKey)
    }
}
