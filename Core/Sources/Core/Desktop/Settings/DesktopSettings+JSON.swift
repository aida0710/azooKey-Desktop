import Foundation

/// Converts each setting between its typed value and the settings file's JSON,
/// rejecting JSON of the wrong type with the setting's field path.
extension DesktopSettings {
    /// The settings file's keys in the order they are written.
    public static let keys = [
        "tree", "live", "halfSpace", "backslash", "optionDirect", "inputStyle", "candidateTextSize",
        "punctuation", "inferenceLimit", "predictiveTyping", "typoCorrection", "debug", "showRelativeScores",
        "learning", "personalization", "profile", "aiEnabled", "aiModel", "aiEndpoint", "includeContext",
        "transformShortcut", "userDictionary", "customTable"
    ]

    private static let shortcutKeys: Set<String> = ["key", "modifiers"]
    private static let dictionaryKeys: Set<String> = ["items"]
    private static let dictionaryEntryKeys: Set<String> = ["id", "reading", "word", "hint"]

    public var json: DesktopSettingsJSON {
        .object(Self.keys.map { .init(key: $0, value: value(forKey: $0)) })
    }

    // The settings file's keys map one to one onto stored properties.
    // swiftlint:disable:next cyclomatic_complexity
    public func value(forKey key: String) -> DesktopSettingsJSON {
        switch key {
        case "tree": .bool(tree)
        case "live": .bool(live)
        case "halfSpace": .bool(halfSpace)
        case "backslash": .bool(backslash)
        case "optionDirect": .bool(optionDirect)
        case "inputStyle": .string(inputStyle.rawValue)
        case "candidateTextSize": .string(candidateTextSize.rawValue)
        case "punctuation": .integer(punctuation.rawValue)
        case "inferenceLimit": .integer(inferenceLimit)
        case "predictiveTyping": .bool(predictiveTyping)
        case "typoCorrection": .bool(typoCorrection)
        case "debug": .bool(debug)
        case "showRelativeScores": .bool(showRelativeScores)
        case "learning": .string(learning.rawValue)
        case "personalization": .string(personalization.rawValue)
        case "profile": .string(profile)
        case "aiEnabled": .bool(aiEnabled)
        case "aiModel": .string(aiModel)
        case "aiEndpoint": .string(aiEndpoint)
        case "includeContext": .bool(includeContext)
        case "transformShortcut": Self.json(for: transformShortcut)
        case "userDictionary": Self.json(for: userDictionary)
        case "customTable": .string(customTable)
        default: .null
        }
    }

    /// Replaces one setting. Only the JSON type and allowed choices are checked
    /// here; `validate()` checks ranges and rules that span settings.
    // swiftlint:disable:next cyclomatic_complexity
    public mutating func setValue(_ value: DesktopSettingsJSON, forKey key: String) throws {
        switch key {
        case "tree": tree = try Self.bool(value, field: key)
        case "live": live = try Self.bool(value, field: key)
        case "halfSpace": halfSpace = try Self.bool(value, field: key)
        case "backslash": backslash = try Self.bool(value, field: key)
        case "optionDirect": optionDirect = try Self.bool(value, field: key)
        case "inputStyle": inputStyle = try Self.choice(value, field: key)
        case "candidateTextSize": candidateTextSize = try Self.choice(value, field: key)
        case "punctuation": punctuation = try Self.punctuation(value, field: key)
        case "inferenceLimit": inferenceLimit = try Self.integer(value, field: key)
        case "predictiveTyping": predictiveTyping = try Self.bool(value, field: key)
        case "typoCorrection": typoCorrection = try Self.bool(value, field: key)
        case "debug": debug = try Self.bool(value, field: key)
        case "showRelativeScores": showRelativeScores = try Self.bool(value, field: key)
        case "learning": learning = try Self.choice(value, field: key)
        case "personalization": personalization = try Self.choice(value, field: key)
        case "profile": profile = try Self.text(value, field: key)
        case "aiEnabled": aiEnabled = try Self.bool(value, field: key)
        case "aiModel": aiModel = try Self.text(value, field: key)
        case "aiEndpoint": aiEndpoint = try Self.text(value, field: key)
        case "includeContext": includeContext = try Self.bool(value, field: key)
        case "transformShortcut": transformShortcut = try Self.shortcut(value)
        case "userDictionary": userDictionary = try Self.dictionary(value)
        case "customTable": customTable = try Self.text(value, field: key)
        default: throw DesktopSettingsProblem.unknownKey(key)
        }
    }

    /// Replaces the settings named in `document`, keeping every other value.
    public mutating func merge(_ document: DesktopSettingsJSON) throws {
        guard case .object(let members) = document else {
            throw DesktopSettingsProblem.invalidValue("")
        }
        if let unknown = members.first(where: { !Self.keys.contains($0.key) }) {
            throw DesktopSettingsProblem.unknownKey(unknown.key)
        }
        for member in members {
            try setValue(member.value, forKey: member.key)
        }
    }

    private static func json(for shortcut: KeyboardShortcut) -> DesktopSettingsJSON {
        .object([.init(key: "key", value: .string(shortcut.key)), .init(key: "modifiers", value: .integer(shortcut.modifiers.rawValue))])
    }

    private static func json(for dictionary: Config.UserDictionary.Value) -> DesktopSettingsJSON {
        .object([.init(key: "items", value: .array(dictionary.items.map { entry in
            var members: [DesktopSettingsJSON.Member] = [
                .init(key: "id", value: .string(entry.id.uuidString)),
                .init(key: "word", value: .string(entry.word)),
                .init(key: "reading", value: .string(entry.reading))
            ]
            // An entry without a hint is written without the member, as Core always stored it.
            if let hint = entry.hint {
                members.append(.init(key: "hint", value: .string(hint)))
            }
            return .object(members)
        }))])
    }

    private static func bool(_ value: DesktopSettingsJSON, field: String) throws -> Bool {
        guard case .bool(let flag) = value else {
            throw DesktopSettingsProblem.invalidValue(field)
        }
        return flag
    }

    private static func integer(_ value: DesktopSettingsJSON, field: String) throws -> Int {
        guard case .integer(let number) = value else {
            throw DesktopSettingsProblem.invalidValue(field)
        }
        return number
    }

    private static func text(_ value: DesktopSettingsJSON, field: String, nonEmpty: Bool = false) throws -> String {
        guard case .string(let text) = value, !nonEmpty || !text.isEmpty else {
            throw DesktopSettingsProblem.invalidValue(field)
        }
        return text
    }

    private static func choice<Value: RawRepresentable<String>>(_ value: DesktopSettingsJSON, field: String) throws -> Value {
        guard let choice = Value(rawValue: try text(value, field: field)) else {
            throw DesktopSettingsProblem.invalidValue(field)
        }
        return choice
    }

    private static func punctuation(_ value: DesktopSettingsJSON, field: String) throws -> Config.PunctuationStyle.Value {
        guard let style = Config.PunctuationStyle.Value(rawValue: try integer(value, field: field)) else {
            throw DesktopSettingsProblem.invalidValue(field)
        }
        return style
    }

    private static func members(
        of value: DesktopSettingsJSON, allowed: Set<String>, path: String
    ) throws -> [String: DesktopSettingsJSON] {
        guard case .object(let members) = value else {
            throw DesktopSettingsProblem.invalidValue(path)
        }
        if let unknown = members.first(where: { !allowed.contains($0.key) }) {
            throw DesktopSettingsProblem.unknownKey(path + unknown.key)
        }
        return Dictionary(members.map { ($0.key, $0.value) }) { first, _ in first }
    }

    private static func shortcut(_ value: DesktopSettingsJSON) throws -> KeyboardShortcut {
        let members = try members(of: value, allowed: shortcutKeys, path: "transformShortcut.")
        let key = try text(members["key"] ?? .null, field: "transformShortcut.key", nonEmpty: true)
        let modifiers = try integer(members["modifiers"] ?? .null, field: "transformShortcut.modifiers")
        return KeyboardShortcut(key: key, modifiers: .init(rawValue: modifiers))
    }

    private static func dictionary(_ value: DesktopSettingsJSON) throws -> Config.UserDictionary.Value {
        let members = try members(of: value, allowed: dictionaryKeys, path: "userDictionary.")
        guard case .array(let items) = members["items"] ?? .null else {
            throw DesktopSettingsProblem.invalidValue("userDictionary.items")
        }
        return .init(items: try items.enumerated().map { index, item in
            try dictionaryEntry(item, path: "userDictionary.items[\(index)].")
        })
    }

    private static func dictionaryEntry(_ value: DesktopSettingsJSON, path: String) throws -> Config.UserDictionaryEntry {
        let members = try members(of: value, allowed: dictionaryEntryKeys, path: path)
        let identifier = try text(members["id"] ?? .null, field: path + "id", nonEmpty: true)
        let reading = try text(members["reading"] ?? .null, field: path + "reading", nonEmpty: true)
        let word = try text(members["word"] ?? .null, field: path + "word", nonEmpty: true)
        guard let id = UUID(uuidString: identifier) else {
            throw DesktopSettingsProblem.invalidValue(path + "id")
        }
        var entry = Config.UserDictionaryEntry(word: word, reading: reading)
        entry.id = id
        switch members["hint"] ?? .null {
        case .null:
            break
        case .string(let hint):
            entry.hint = hint
        default:
            throw DesktopSettingsProblem.invalidValue(path + "hint")
        }
        return entry
    }
}
