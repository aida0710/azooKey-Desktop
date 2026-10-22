import Foundation
import KanaKanjiConverterModule

/// Reads and writes the preferences the converter actually runs with.
extension DesktopSettings {
    public static func current() -> DesktopSettings {
        DesktopSettings(
            tree: Config.TreeCandidates().value,
            live: Config.LiveConversion().value,
            halfSpace: Config.TypeHalfSpace().value,
            backslash: Config.TypeBackSlash().value,
            optionDirect: Config.OptionDirectFullWidthInput().value,
            inputStyle: Config.InputStyle().value,
            candidateTextSize: Config.CandidateTextSize().value,
            punctuation: Config.PunctuationStyle().value,
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            predictiveTyping: Config.DebugPredictiveTyping().value,
            typoCorrection: Config.DebugTypoCorrection().value,
            debug: Config.DebugWindow().value,
            showRelativeScores: Config.ShowRelativeScores().value,
            learning: Config.Learning().value,
            personalization: Config.ZenzaiPersonalizationLevel().value,
            profile: Config.ZenzaiProfile().value,
            aiEnabled: Config.AIBackendPreference().value == .openAI,
            aiModel: Config.OpenAiModelName().value,
            aiEndpoint: Config.OpenAiApiEndpoint().value,
            includeContext: Config.IncludeContextInAITransform().value,
            transformShortcut: Config.TransformShortcut().value,
            aiPromptLanguage: Config.AIPromptLanguage().value,
            userDictionary: Config.UserDictionary().value,
            customTable: CustomInputTableStore.load() ?? ""
        )
    }

    /// Stores these values as the converter's preferences. The user
    /// dictionary is compiled separately by its save transaction.
    public func applyToConfig() throws {
        try validate()
        if customTable.isEmpty {
            try CustomInputTableStore.clear()
        } else {
            try Self.checkTable(customTable)
            _ = try CustomInputTableStore.save(exported: customTable)
            guard CustomInputTableStore.registerIfExists() else {
                throw DesktopSettingsProblem(.engineRejected)
            }
        }
        Config.TreeCandidates().value = tree
        Config.CandidateTextSize().value = candidateTextSize
        Config.ShowRelativeScores().value = showRelativeScores
        Config.LiveConversion().value = live
        Config.TypeHalfSpace().value = halfSpace
        Config.TypeBackSlash().value = backslash
        Config.OptionDirectFullWidthInput().value = optionDirect
        Config.InputStyle().value = inputStyle
        Config.Learning().value = learning
        Config.PunctuationStyle().value = punctuation
        Config.ZenzaiProfile().value = profile
        Config.ZenzaiPersonalizationLevel().value = personalization
        Config.ZenzaiInferenceLimit().value = inferenceLimit
        Config.DebugPredictiveTyping().value = predictiveTyping
        Config.DebugTypoCorrection().value = typoCorrection
        Config.DebugWindow().value = debug
        Config.AIBackendPreference().value = aiEnabled ? .openAI : .off
        Config.OpenAiModelName().value = aiModel
        Config.OpenAiApiEndpoint().value = aiEndpoint
        Config.IncludeContextInAITransform().value = includeContext
        Config.TransformShortcut().value = transformShortcut
        Config.AIPromptLanguage().value = aiPromptLanguage
        Config.userDefaults.synchronize()
    }

    /// The converter must be able to load the table before it replaces the stored one.
    private static func checkTable(_ table: String) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("azookey-table-\(UUID().uuidString).tsv")
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        try table.write(to: temporary, atomically: true, encoding: .utf8)
        _ = try InputStyleManager.loadTable(from: temporary)
    }
}
