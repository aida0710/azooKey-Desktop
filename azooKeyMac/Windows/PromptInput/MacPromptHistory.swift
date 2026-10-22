import Core
import Foundation

/// Core's instruction history at the place the macOS app can reach.
enum MacPromptHistory {
    private static let fileName = "prompts.json"

    /// The sandboxed input method reaches only its app group, so the file is
    /// kept there instead of beside the desktop bridge's settings file. The
    /// history of earlier versions is imported the first time.
    static func open() -> AIPromptHistory {
        let history = AIPromptHistory(
            fileURL: AppGroup.applicationSupportDirectoryURL().appendingPathComponent(fileName)
        )
        let savedItems = PreferencesPromptHistory.items()
        if !savedItems.isEmpty {
            // A failed import is tried again the next time the history opens.
            try? history.importItems(savedItems)
        }
        return history
    }
}
