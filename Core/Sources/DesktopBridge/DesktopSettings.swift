import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct DesktopSettings: Codable {
    var tree = Config.TreeCandidates().value
    var live = Config.LiveConversion().value
    var halfSpace = Config.TypeHalfSpace().value
    var backslash = Config.TypeBackSlash().value
    var optionDirect = Config.OptionDirectFullWidthInput().value
    var inputStyle = Config.InputStyle().value
    var learning = Config.Learning().value
    var punctuation = Config.PunctuationStyle().value
    var profile = Config.ZenzaiProfile().value
    var personalization = Config.ZenzaiPersonalizationLevel().value
    var inferenceLimit = Config.ZenzaiInferenceLimit().value
    var predictiveTyping = Config.DebugPredictiveTyping().value
    var typoCorrection = Config.DebugTypoCorrection().value
    var debug = Config.DebugWindow().value
    var aiEnabled = Config.AIBackendPreference().value == .openAI
    var aiModel = Config.OpenAiModelName().value
    var aiEndpoint = Config.OpenAiApiEndpoint().value
    var includeContext = Config.IncludeContextInAITransform().value
    var transformShortcut = Config.TransformShortcut().value
    var userDictionary = Config.UserDictionary().value
    var customTable = CustomInputTableStore.load() ?? ""

    func apply() throws {
        guard (1...100).contains(inferenceLimit), profile.count <= 4096,
              ["http", "https"].contains(URL(string: aiEndpoint)?.scheme ?? "") else {
            throw BridgeMain.ProtocolError.invalidRequest
        }
        guard !transformShortcut.key.isEmpty, transformShortcut.modifiers.rawValue & ~15 == 0,
              inputStyle != .custom || !customTable.isEmpty else { throw BridgeMain.ProtocolError.invalidRequest }
        if !customTable.isEmpty {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("azookey-table-\(UUID().uuidString).tsv")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try customTable.write(to: temporary, atomically: true, encoding: .utf8)
            _ = try InputStyleManager.loadTable(from: temporary)
            _ = try CustomInputTableStore.save(exported: customTable)
            guard CustomInputTableStore.registerIfExists() else { throw BridgeMain.ProtocolError.invalidRequest }
        } else {
            try CustomInputTableStore.clear()
        }
        Config.TreeCandidates().value = tree
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
        Config.userDefaults.synchronize()
    }
}
