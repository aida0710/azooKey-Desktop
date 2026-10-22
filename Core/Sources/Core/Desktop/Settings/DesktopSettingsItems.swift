import Foundation

/// The definition of every setting in the settings file.
enum DesktopSettingsItems {
    /// Typo correction weights and personalization models are marisa tries,
    /// which the converter cannot read on Windows.
    static let marisaUnavailable: [DesktopPlatform: String] = [.windows: "settings.unavailable.marisa_windows"]

    static let all: [DesktopSettingItem] = [
        .init(key: "tree", control: .toggle, labelKey: "settings.tree", resetsToInputDefault: true),
        .init(key: "live", control: .toggle, labelKey: "settings.live", resetsToInputDefault: true),
        .init(key: "halfSpace", control: .toggle, labelKey: "settings.halfSpace", resetsToInputDefault: true),
        .init(key: "backslash", control: .toggle, labelKey: "settings.backslash", resetsToInputDefault: true),
        .init(key: "optionDirect", control: .toggle, labelKey: "settings.optionDirect", resetsToInputDefault: true),
        .init(key: "inputStyle", control: .choice, labelKey: "settings.inputStyle", choices: inputStyleChoices,
              resetsToInputDefault: true),
        .init(key: "candidateTextSize", control: .choice, labelKey: "candidate.textSize", choices: candidateTextSizeChoices,
              resetsToInputDefault: true),
        .init(key: "punctuation", control: .choice, labelKey: "settings.punctuation", choices: punctuationChoices,
              resetsToInputDefault: true),
        .init(key: "inferenceLimit", control: .integer, labelKey: "settings.inferenceLimit",
              range: DesktopSettings.inferenceLimitRange, resetsToInputDefault: true),
        .init(key: "predictiveTyping", control: .toggle, labelKey: "settings.predictiveTyping", resetsToInputDefault: true),
        .init(key: "typoCorrection", control: .toggle, labelKey: "settings.typoCorrection", resetsToInputDefault: true,
              unavailableReasons: marisaUnavailable),
        .init(key: "debug", control: .toggle, labelKey: "settings.debug", resetsToInputDefault: true),
        .init(key: "showRelativeScores", control: .toggle, labelKey: "candidate.score.show",
              descriptionKey: "candidate.score.explanation", resetsToInputDefault: true),
        .init(key: "learning", control: .choice, labelKey: "learning.title", descriptionKey: "learning.retention",
              choices: Config.Learning.Value.allCases.map { .init(value: .string($0.rawValue), labelKey: $0.labelKey) },
              keptOnRecovery: true),
        .init(key: "personalization", control: .choice, labelKey: "settings.personalization",
              descriptionKey: "settings.personalization.explanation", choices: personalizationChoices,
              keptOnRecovery: true, unavailableReasons: marisaUnavailable),
        .init(key: "profile", control: .text, labelKey: "settings.profile",
              maximumCharacters: DesktopSettings.maximumProfileLength, keptOnRecovery: true),
        .init(key: "aiEnabled", control: .toggle, labelKey: "ai.backend.external", keptOnRecovery: true),
        .init(key: "aiModel", control: .text, labelKey: "ai.model", keptOnRecovery: true),
        .init(key: "aiEndpoint", control: .text, labelKey: "ai.endpoint", keptOnRecovery: true),
        .init(key: "includeContext", control: .toggle, labelKey: "ai.scope.include-context", keptOnRecovery: true),
        .init(key: "transformShortcut", control: .shortcut, labelKey: "ai.shortcut", accessKey: "S", keptOnRecovery: true),
        .init(key: "userDictionary", control: .dictionary, labelKey: "settings.dictionary_edit",
              descriptionKey: "settings.dictionary_separate_save", keptOnRecovery: true),
        .init(key: "customTable", control: .multilineText, labelKey: "settings.custom-table", keptOnRecovery: true)
    ]

    private static let inputStyleChoices: [DesktopSettingItem.Choice] = [
        Config.InputStyle.Value.default, .defaultAZIK, .defaultKanaJIS, .defaultKanaUS, .custom
    ].map { .init(value: .string($0.rawValue), labelKey: "settings.inputStyle.\($0.rawValue)") }

    private static let candidateTextSizeChoices: [DesktopSettingItem.Choice] = Config.CandidateTextSize.Value.allCases.map {
        .init(value: .string($0.rawValue), labelKey: "candidate.textSize.\($0.rawValue)")
    }

    private static let punctuationChoices: [DesktopSettingItem.Choice] = [
        (Config.PunctuationStyle.Value.kutenAndToten, "kutenAndToten"), (.kutenAndComma, "kutenAndComma"),
        (.periodAndToten, "periodAndToten"), (.periodAndComma, "periodAndComma")
    ].map { style, name in .init(value: .integer(style.rawValue), labelKey: "settings.punctuation.\(name)") }

    private static let personalizationChoices: [DesktopSettingItem.Choice] = [
        Config.ZenzaiPersonalizationLevel.Value.off, .soft, .normal, .hard
    ].map { .init(value: .string($0.rawValue), labelKey: "settings.personalization.\($0.rawValue)") }
}
