import Core
import Foundation
import KanaKanjiConverterModule

/// Validated, process-local settings; neither role writes the shared preference or table files.
@MainActor
struct DesktopWorkerSettingsRuntime {
    static let contract = "full"
    static let unsupportedFeatures = ["live", "predictiveTyping", "ai", "reconversion", "debug"]
    // The upstream registry has no unregister API; bound distinct tables over this process's lifetime.
    private static var registeredTableNames: Set<String> = []

    let settings: DesktopWorkerSettings
    let identity: Data
    let inputStyle: InputStyle
    let customInputTableRevisions: [String: String]
    private let overrides: [String: Config.OverrideValue]

    init(_ settings: DesktopWorkerSettings) throws {
        try Self.validate(settings)
        self.settings = settings
        identity = try Self.identity(settings)
        overrides = try settings.configOverrides()
        let revisions = try Self.registerTable(settings.customTable)
        customInputTableRevisions = revisions
        switch settings.inputStyle {
        case .default: inputStyle = .mapped(id: .defaultRomanToKana)
        case .defaultAZIK: inputStyle = .mapped(id: .defaultAZIK)
        case .defaultKanaJIS: inputStyle = .mapped(id: .defaultKanaJIS)
        case .defaultKanaUS: inputStyle = .mapped(id: .defaultKanaUS)
        case .custom:
            guard let name = revisions.keys.first else { throw DesktopWorkerSettingsFailure.invalidSettings }
            inputStyle = .mapped(id: .tableName(name))
        }
    }

    func perform<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try Config.withOverrides(overrides, perform: operation)
    }

    static func isChange(
        _ settings: DesktopWorkerSettings, revision: Int, currentRevision: Int, current: Self?
    ) throws -> Bool {
        guard revision >= 0 else { throw DesktopWorkerSettingsFailure.invalidSettings }
        if revision == currentRevision, let current {
            guard try identity(settings) == current.identity else { throw DesktopWorkerSettingsFailure.staleSettings }
            return false
        }
        guard revision > currentRevision || (current == nil && currentRevision == 0 && revision == 0) else {
            throw DesktopWorkerSettingsFailure.staleSettings
        }
        return true
    }

    static func identity(_ settings: DesktopWorkerSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(settings)
        guard encoded.count <= DesktopWorkerProtocolLimits.settingsBytes else {
            throw DesktopWorkerSettingsFailure.invalidSettings
        }
        return encoded
    }

    private static func validate(_ settings: DesktopWorkerSettings) throws {
        guard !settings.live, !settings.predictiveTyping, !settings.aiEnabled, !settings.debug else {
            throw DesktopWorkerSettingsFailure.unsupportedSettings
        }
        do {
            try DesktopSettingsValidation.conversion(inferenceLimit: settings.inferenceLimit, profile: settings.profile)
        } catch {
            throw DesktopWorkerSettingsFailure.invalidSettings
        }
        guard !settings.transformShortcut.key.isEmpty, settings.transformShortcut.modifiers.rawValue & ~15 == 0,
              settings.inputStyle != .custom || !settings.customTable.isEmpty else {
            throw DesktopWorkerSettingsFailure.invalidSettings
        }
        if !settings.customTable.isEmpty {
            guard case .fullyValid = InputStyleManager.checkFormat(content: settings.customTable) else {
                throw DesktopWorkerSettingsFailure.invalidSettings
            }
        }
    }

    private static func registerTable(_ contents: String) throws -> [String: String] {
        guard !contents.isEmpty else {
            return [:]
        }
        let revision = CompositionSnapshot.customInputTableRevision(exportedTable: contents)
        let name = CustomInputTableStore.tableName + "." + revision
        if registeredTableNames.contains(name) {
            return [name: revision]
        }
        guard registeredTableNames.count < CompositionSnapshotLimits.customTableCount else {
            throw DesktopWorkerSettingsFailure.invalidSettings
        }
        // The public upstream parser accepts a URL only. This temporary is never the shared custom table.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("azookey-worker-table-\(UUID().uuidString).tsv")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try contents.write(to: temporary, atomically: true, encoding: .utf8)
            let table = try InputStyleManager.loadTable(from: temporary)
            guard !(try InputStyleManager.exportTable(table)).isEmpty else {
                throw DesktopWorkerSettingsFailure.invalidSettings
            }
            InputStyleManager.registerInputStyle(table: table, for: name)
        } catch {
            throw DesktopWorkerSettingsFailure.invalidSettings
        }
        registeredTableNames.insert(name)
        return [name: revision]
    }
}

private extension DesktopWorkerSettings {
    func configOverrides() throws -> [String: Config.OverrideValue] {
        let encoder = JSONEncoder()
        return [
            Config.TreeCandidates.key: .boolean(tree),
            Config.CandidateTextSize.key: .string(candidateTextSize.rawValue),
            Config.ShowRelativeScores.key: .boolean(showRelativeScores),
            Config.LiveConversion.key: .boolean(live),
            Config.TypeHalfSpace.key: .boolean(halfSpace),
            Config.TypeBackSlash.key: .boolean(backslash),
            Config.OptionDirectFullWidthInput.key: .boolean(optionDirect),
            Config.InputStyle.key: .encoded(try encoder.encode(inputStyle)),
            Config.Learning.key: .encoded(try encoder.encode(learning)),
            Config.PunctuationStyle.key: .encoded(try encoder.encode(punctuation)),
            Config.ZenzaiProfile.key: .string(profile),
            Config.ZenzaiPersonalizationLevel.key: .encoded(try encoder.encode(personalization)),
            Config.ZenzaiInferenceLimit.key: .integer(inferenceLimit),
            Config.DebugPredictiveTyping.key: .boolean(predictiveTyping),
            Config.DebugTypoCorrection.key: .boolean(typoCorrection),
            Config.DebugWindow.key: .boolean(debug),
            Config.AIBackendPreference.key: .encoded(try encoder.encode(Config.AIBackendPreference.Value.off)),
            Config.TransformShortcut.key: .encoded(try encoder.encode(transformShortcut))
        ]
    }
}
