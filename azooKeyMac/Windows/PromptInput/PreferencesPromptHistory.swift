import Core
import Foundation

/// The instruction history earlier macOS versions kept in the preferences.
/// It is read only to import it into Core's history file.
enum PreferencesPromptHistory {
    /// The item those versions wrote; only the instruction is always present.
    private struct SavedItem: Decodable {
        let prompt: String
        let isPinned: Bool?
        let lastUsed: Date?
        let shortcut: KeyboardShortcut?
    }

    /// Empty when nothing was saved or the saved value cannot be read.
    static func items() -> [AIPromptHistory.Item] {
        let key = Config.PromptHistory.key
        guard let data = Config.data(forKey: key) ?? Config.string(forKey: key)?.data(using: .utf8) else {
            return []
        }
        if let saved = try? JSONDecoder().decode([SavedItem].self, from: data) {
            return saved.map {
                AIPromptHistory.Item(
                    prompt: $0.prompt, pinned: $0.isPinned ?? false,
                    lastUsed: $0.lastUsed?.timeIntervalSince1970 ?? 0, shortcut: $0.shortcut
                )
            }
        }
        // The oldest versions kept only the instructions, most recent first;
        // equal times keep that order when Core ranks them.
        if let prompts = try? JSONDecoder().decode([String].self, from: data) {
            return prompts.map { AIPromptHistory.Item(prompt: $0, pinned: false, lastUsed: 0, shortcut: nil) }
        }
        return []
    }
}
