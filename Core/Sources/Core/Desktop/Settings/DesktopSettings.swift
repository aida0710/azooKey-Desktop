import Foundation

/// Every preference a desktop settings screen edits, named as in the settings file.
public struct DesktopSettings: Sendable {
    public var tree: Bool
    public var live: Bool
    public var halfSpace: Bool
    public var backslash: Bool
    public var optionDirect: Bool
    public var inputStyle: Config.InputStyle.Value
    public var candidateTextSize: Config.CandidateTextSize.Value
    public var punctuation: Config.PunctuationStyle.Value
    public var inferenceLimit: Int
    public var predictiveTyping: Bool
    public var typoCorrection: Bool
    public var debug: Bool
    public var showRelativeScores: Bool
    public var learning: Config.Learning.Value
    public var personalization: Config.ZenzaiPersonalizationLevel.Value
    public var profile: String
    public var aiEnabled: Bool
    public var aiModel: String
    public var aiEndpoint: String
    public var includeContext: Bool
    public var transformShortcut: KeyboardShortcut
    public var userDictionary: Config.UserDictionary.Value
    public var customTable: String

    /// The values a new installation starts with.
    public static let defaults = DesktopSettings(
        tree: Config.TreeCandidates.default,
        live: Config.LiveConversion.default,
        halfSpace: Config.TypeHalfSpace.default,
        backslash: Config.TypeBackSlash.default,
        optionDirect: Config.OptionDirectFullWidthInput.default,
        inputStyle: Config.InputStyle.default,
        candidateTextSize: .standard,
        punctuation: Config.PunctuationStyle.default,
        inferenceLimit: Config.ZenzaiInferenceLimit.default,
        predictiveTyping: Config.DebugPredictiveTyping.default,
        typoCorrection: Config.DebugTypoCorrection.default,
        debug: Config.DebugWindow.default,
        showRelativeScores: Config.ShowRelativeScores.default,
        learning: Config.Learning.default,
        personalization: Config.ZenzaiPersonalizationLevel.default,
        profile: "",
        aiEnabled: false,
        aiModel: Config.OpenAiModelName.default,
        aiEndpoint: Config.OpenAiApiEndpoint.default,
        includeContext: Config.IncludeContextInAITransform.default,
        transformShortcut: Config.TransformShortcut.default,
        userDictionary: Config.UserDictionary.default,
        customTable: ""
    )
}

extension DesktopSettings: Equatable {
    /// Two settings are equal when they would be written as the same document.
    public static func == (lhs: DesktopSettings, rhs: DesktopSettings) -> Bool {
        lhs.json == rhs.json
    }
}

extension DesktopSettings: Encodable {
    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}
