import Core
import Foundation

/// Complete settings shared by the reading and candidate roles; dictionaries have a separate transaction.
struct DesktopWorkerSettings: Codable, Equatable {
    var tree: Bool
    var candidateTextSize: Config.CandidateTextSize.Value
    var showRelativeScores: Bool
    var live: Bool
    var halfSpace: Bool
    var backslash: Bool
    var optionDirect: Bool
    var inputStyle: Config.InputStyle.Value
    var learning: Config.Learning.Value
    var punctuation: Config.PunctuationStyle.Value
    var profile: String
    var personalization: Config.ZenzaiPersonalizationLevel.Value
    var inferenceLimit: Int
    var predictiveTyping: Bool
    var typoCorrection: Bool
    var debug: Bool
    var aiEnabled: Bool
    var transformShortcut: KeyboardShortcut
    var customTable: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tree, candidateTextSize, showRelativeScores, live, halfSpace, backslash, optionDirect, inputStyle
        case learning, punctuation, profile, personalization, inferenceLimit, predictiveTyping, typoCorrection
        case debug, aiEnabled, transformShortcut, customTable
    }
}

extension DesktopWorkerSettings {
    init(_ settings: DesktopSettings) {
        self.init(tree: settings.tree, candidateTextSize: settings.candidateTextSize,
                  showRelativeScores: settings.showRelativeScores, live: settings.live,
                  halfSpace: settings.halfSpace, backslash: settings.backslash, optionDirect: settings.optionDirect,
                  inputStyle: settings.inputStyle, learning: settings.learning, punctuation: settings.punctuation,
                  profile: settings.profile, personalization: settings.personalization, inferenceLimit: settings.inferenceLimit,
                  predictiveTyping: settings.predictiveTyping, typoCorrection: settings.typoCorrection,
                  debug: settings.debug, aiEnabled: settings.aiEnabled,
                  transformShortcut: settings.transformShortcut, customTable: settings.customTable)
    }

    init(from decoder: any Decoder) throws {
        try DesktopReadingProtocolValidation.keys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let shortcut = try fields.superDecoder(forKey: .transformShortcut)
        try DesktopReadingProtocolValidation.keys(shortcut, allowed: ["key", "modifiers"])
        self.init(tree: try fields.decode(Bool.self, forKey: .tree),
                  candidateTextSize: try fields.decode(Config.CandidateTextSize.Value.self, forKey: .candidateTextSize),
                  showRelativeScores: try fields.decode(Bool.self, forKey: .showRelativeScores),
                  live: try fields.decode(Bool.self, forKey: .live),
                  halfSpace: try fields.decode(Bool.self, forKey: .halfSpace),
                  backslash: try fields.decode(Bool.self, forKey: .backslash),
                  optionDirect: try fields.decode(Bool.self, forKey: .optionDirect),
                  inputStyle: try fields.decode(Config.InputStyle.Value.self, forKey: .inputStyle),
                  learning: try fields.decode(Config.Learning.Value.self, forKey: .learning),
                  punctuation: try fields.decode(Config.PunctuationStyle.Value.self, forKey: .punctuation),
                  profile: try fields.decode(String.self, forKey: .profile),
                  personalization: try fields.decode(Config.ZenzaiPersonalizationLevel.Value.self, forKey: .personalization),
                  inferenceLimit: try fields.decode(Int.self, forKey: .inferenceLimit),
                  predictiveTyping: try fields.decode(Bool.self, forKey: .predictiveTyping),
                  typoCorrection: try fields.decode(Bool.self, forKey: .typoCorrection),
                  debug: try fields.decode(Bool.self, forKey: .debug),
                  aiEnabled: try fields.decode(Bool.self, forKey: .aiEnabled),
                  transformShortcut: try KeyboardShortcut(from: shortcut),
                  customTable: try fields.decode(String.self, forKey: .customTable))
    }
}

enum DesktopWorkerSettingsFailure: String, Error {
    case invalidSettings = "invalid_worker_settings"
    case unsupportedSettings = "unsupported_worker_settings"
    case staleSettings = "stale_worker_settings"
    case settingsBusy = "worker_settings_busy"
    case fullSettingsRequired = "full_settings_required"
}
