import Foundation

/// The settings screen's tabs, grouped by the task the user wants to perform.
enum DesktopSettingsPages {
    static func pages(for platform: DesktopPlatform) -> [DesktopSettingsPage] {
        let marisaReason = DesktopSettingsItems.marisaUnavailable[platform]
        return [
            .init(id: "input", titleKey: "settings.page.input", elements: [
                .setting(key: "halfSpace"), .setting(key: "backslash"), .setting(key: "optionDirect"),
                .setting(key: "inputStyle"), .setting(key: "punctuation"), .setting(key: "customTable")
            ]),
            .init(id: "conversion", titleKey: "settings.page.conversion", elements: [
                .setting(key: "tree"), .setting(key: "live"), .setting(key: "candidateTextSize"),
                .setting(key: "showRelativeScores"), .setting(key: "inferenceLimit"), .setting(key: "predictiveTyping"),
                .setting(key: "typoCorrection"), .setting(key: "debug"),
                .action(.init(id: "downloadTypoWeights", labelKey: "settings.downloadTypoWeights", unavailableReasonKey: marisaReason))
            ]),
            .init(id: "dictionary", titleKey: "settings.page.dictionary", elements: [
                .setting(key: "learning"),
                .action(.init(id: "resetLearning", labelKey: "learning.reset.action", unavailableReasonKey: nil)),
                .setting(key: "profile"), .setting(key: "personalization"),
                .action(.init(id: "importPersonalization", labelKey: "settings.importPersonalization",
                              unavailableReasonKey: marisaReason)),
                .setting(key: "userDictionary")
            ]),
            .init(id: "ai", titleKey: "settings.page.ai", elements: [
                .setting(key: "aiEnabled"), .setting(key: "includeContext"), .note(textKey: aiProcessingNote(for: platform)),
                .setting(key: "aiModel"), .setting(key: "aiEndpoint"), .setting(key: "transformShortcut"),
                .secret(.init(id: "apiKey", labelKey: "ai.api-key", placeholderKey: "ai.api-key-placeholder",
                              descriptionKey: "ai.scope.api-key", accessKey: "K"))
            ]),
            .init(id: "support", titleKey: "settings.page.support", elements: [.support])
        ]
    }

    /// Only macOS has an on-device AI, so the explanation differs per platform.
    private static func aiProcessingNote(for platform: DesktopPlatform) -> String {
        switch platform {
        case .macOS: "ai.scope.processing"
        case .linux: "ai.scope.processing-linux"
        case .windows: "ai.scope.processing-windows"
        }
    }
}
