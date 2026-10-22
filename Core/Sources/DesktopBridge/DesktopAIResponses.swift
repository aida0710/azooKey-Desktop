import Core
import Foundation

/// The `ai` object of a `key` response: what the platform should show next.
struct DesktopAIKeyResult: Encodable {
    struct Review: Encodable {
        let id: Int
        let target: String
        /// Host and port only; absent when the endpoint cannot be shown.
        let destination: String?
        let includeContext: Bool
        let bindings: [DesktopKeyBinding]
    }

    struct Prompt: Encodable {
        let initialPrompt: String
    }

    var review: Review?
    var prompt: Prompt?
}

struct DesktopIMEShortcutsResponse: Encodable {
    let shortcuts: [DesktopKeyBinding]
}

struct DesktopShortcutTextResponse: Encodable {
    var shortcut: KeyboardShortcut?
    var shortcutText: String?
    var shortcutError: DesktopShortcutText.Failure?
}

struct DesktopAIReviewSendResponse: Encodable {
    /// The `ai` operation's arguments; absent when the review no longer applies.
    var request: AIRequestArguments?
    /// Passed back with the `suggestions` operation for the reviewed composition.
    var generation: Int?
    var reading: String?
}

/// Every `ai-transform-*` response names its transformation. A request for a
/// transformation that is no longer current is answered with `stale`.
struct DesktopAITransformationResponse: Encodable {
    struct HistoryItem: Encodable {
        let prompt: String
        let pinned: Bool
        let shortcutText: String
    }

    var transformation: Int?
    var stale: Bool?
    // ai-transform-open
    var target: String?
    var destination: String?
    var includeContext: Bool?
    var needsWitness: Bool?
    var contextCharacters: Int?
    var history: [HistoryItem]?
    // ai-transform-target, -result, -reject
    var targetAvailable: Bool?
    // ai-transform-preview
    var previewRefusal: AISelectedTextTransformation.PreviewRefusal?
    var historyError: String?
    var revision: Int?
    var request: AIRequestArguments?
    // ai-transform-result
    var accepted: Bool?
    var text: String?
    // ai-transform-confirm
    var confirmed: Bool?
    // ai-transform-check
    var matches: Bool?
    // ai-transform-take
    var replacement: String?
}
