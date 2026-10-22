import Core
import Foundation

/// The `ai` object of a bridge request: facts and choices for AI decisions.
/// Which fields an operation reads is listed in docs/ai-bridge-protocol.md.
struct DesktopAIRequest: Decodable {
    /// `key`: the focused field currently has a non-empty selection.
    var hasSelection: Bool?
    /// `ai-review-send`: the review the user confirmed.
    var review: Int?
    /// `ai-review-send`, `ai-transform-preview`: the user's context choice.
    var includeContext: Bool?
    /// `ai-transform-*`: the transformation this request belongs to.
    var transformation: Int?
    var field: AITextField?
    var witness: AISelectionWitness?
    /// `ai-transform-preview`: the instruction and how to keep it in the history.
    var prompt: String?
    var pinned: Bool?
    var shortcutText: String?
    /// `ai-shortcut`: a stored shortcut to show as text.
    var shortcut: KeyboardShortcut?
    /// `ai-transform-result`: the request this result answers.
    var revision: Int?
    var text: String?
    var inputContextChanged: Bool?
}
