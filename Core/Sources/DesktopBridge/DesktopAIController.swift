import Core
import Foundation

/// AI decisions for every desktop platform: suggestion reviews, the
/// selected-text transformation, prompt history and the shortcuts that
/// reach Core. One review and one transformation are kept per input context.
@MainActor
final class DesktopAIController {
    // Internal so the transformation operations in their own file can use them.
    let promptHistory: AIPromptHistory
    var transformations: [String: AISelectedTextTransformation] = [:]
    private var reviews: [String: AISuggestionReview] = [:]
    private var lastIdentifier = 0

    init(promptHistory: AIPromptHistory) {
        self.promptHistory = promptHistory
    }

    /// The prompt history lives beside the desktop settings file.
    static func promptHistoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        DesktopDictionarySettingsFile.settingsURL(environment: environment)
            .deletingLastPathComponent().appendingPathComponent("prompts.json")
    }

    /// Operations that do not touch a conversion session, so they never wait
    /// for one to be created.
    func response(to request: BridgeRequest, context: String) throws -> (any Encodable)? {
        switch request.operation {
        case "ime-shortcuts":
            return DesktopIMEShortcutsResponse(shortcuts: shortcutBindings())
        case "ai-shortcut":
            return shortcutText(for: request.ai)
        case let operation where operation.hasPrefix("ai-transform-"):
            guard let ai = request.ai else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            return try transformationResponse(to: operation, ai: ai, context: context)
        default:
            return nil
        }
    }

    /// Sending a review is valid only while its composition is unchanged.
    func sessionResponse(to request: BridgeRequest, session: DesktopSession, context: String) throws -> (any Encodable)? {
        guard request.operation == "ai-review-send" else {
            return nil
        }
        guard let identifier = request.ai?.review, let includeContext = request.ai?.includeContext else {
            throw BridgeMain.ProtocolError.invalidRequest
        }
        guard let review = reviews[context], review.id == identifier else {
            return DesktopAIReviewSendResponse()
        }
        reviews[context] = nil
        let current = session.snapshot()
        guard !session.privateInput, AIDesktopConfiguration.current().isEnabled,
              review.isCurrent(generation: current.generation, reading: current.reading) else {
            return DesktopAIReviewSendResponse()
        }
        return DesktopAIReviewSendResponse(
            request: review.content.arguments(includeContext: includeContext),
            generation: review.generation, reading: review.reading
        )
    }

    /// The `key` operation. A prompt shortcut on a selection opens the prompt
    /// without editing the composition; a suggestion request opens a review.
    func key(_ event: KeyEventCore, request: BridgeRequest, session: DesktopSession, context: String) -> DesktopSnapshot {
        let configuration = AIDesktopConfiguration.current()
        let mayUseAI = configuration.isEnabled && !session.privateInput
        let hasSelection = request.ai?.hasSelection ?? false
        let doubleTap = request.doubleTap ?? false
        reviews[context] = nil
        if hasSelection, mayUseAI,
           let initialPrompt = promptShortcuts(configuration).initialPrompt(for: event, doubleTap: doubleTap) {
            var snapshot = session.snapshot()
            snapshot.ai = DesktopAIKeyResult(prompt: .init(initialPrompt: initialPrompt))
            return snapshot
        }
        var snapshot = session.key(event, doubleTap: doubleTap)
        switch snapshot.request {
        case "prompt"? where hasSelection:
            snapshot.ai = DesktopAIKeyResult(prompt: .init(initialPrompt: ""))
        case "prompt"?, "replace"?, "predict"?:
            guard mayUseAI else {
                break
            }
            let review = AISuggestionReview(
                id: nextIdentifier(), reading: snapshot.reading, generation: snapshot.generation,
                before: request.leftContext ?? "", after: request.rightContext ?? "", configuration: configuration
            )
            reviews[context] = review
            snapshot.ai = DesktopAIKeyResult(review: .init(
                id: review.id, target: review.content.target, destination: review.content.destination,
                includeContext: review.content.includesContextByDefault, bindings: AISuggestionReview.keyBindings
            ))
        default:
            break
        }
        return snapshot
    }

    func close(context: String) {
        reviews[context] = nil
        transformations[context] = nil
    }

    /// Reviews and transformations share one sequence, so an identifier never repeats in a process.
    func nextIdentifier() -> Int {
        lastIdentifier += 1
        return lastIdentifier
    }

    private func promptShortcuts(_ configuration: AIDesktopConfiguration) -> AIPromptShortcuts {
        AIPromptShortcuts(pinned: promptHistory.pinnedShortcuts(), transformShortcut: configuration.transformShortcut)
    }

    private func shortcutBindings() -> [DesktopKeyBinding] {
        let configuration = AIDesktopConfiguration.current()
        // Prompt chords are routed only while they can open a prompt.
        return IMEShortcuts.bindings + (configuration.isEnabled ? promptShortcuts(configuration).bindings : [])
    }

    private func shortcutText(for ai: DesktopAIRequest?) -> DesktopShortcutTextResponse {
        if let shortcut = ai?.shortcut {
            return DesktopShortcutTextResponse(shortcut: shortcut, shortcutText: DesktopShortcutText.text(for: shortcut))
        }
        do {
            let shortcut = try DesktopShortcutText.parse(ai?.shortcutText ?? "")
            return DesktopShortcutTextResponse(shortcut: shortcut, shortcutText: DesktopShortcutText.text(for: shortcut))
        } catch {
            return DesktopShortcutTextResponse(shortcutError: error)
        }
    }
}
