import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public enum UserDictionaryValidation {
    public enum Field: String, Codable, Sendable {
        case word
        case reading
    }

    public enum Reason: String, Codable, Sendable {
        case empty
        case controlCharacter
        case unsupportedCharacter
    }

    public struct Issue: Codable, Equatable, Sendable {
        public let rowID: UUID
        public let field: Field
        public let reason: Reason
        public let characters: String

        public init(rowID: UUID, field: Field, reason: Reason, characters: String = "") {
            self.rowID = rowID
            self.field = field
            self.reason = reason
            self.characters = characters
        }
    }

    public struct InvalidEntries: Error, Sendable {
        public let issues: [Issue]
    }

    public enum ResourceError: Error, Sendable {
        case missingCharacterTable
    }

    public static func validate(
        items: [Config.UserDictionaryEntry],
        charIDFileURL: URL? = nil
    ) throws -> [Issue] {
        guard !items.isEmpty else {
            return []
        }
        let characterTable = try Self.characterTable(at: charIDFileURL)
        return Self.validate(items: items, supportedCharacters: characterTable.characters)
    }

    static func characterTable(at suppliedURL: URL?) throws -> (url: URL, characters: Set<Character>) {
        guard let url = suppliedURL ?? CompiledUserDictionaryStore.defaultCharIDFileURL() else {
            throw ResourceError.missingCharacterTable
        }
        return (url, Set(try String(contentsOf: url, encoding: .utf8)))
    }

    static func validate(
        items: [Config.UserDictionaryEntry],
        supportedCharacters: Set<Character>
    ) -> [Issue] {
        items.flatMap { item in
            Self.fieldIssues(value: item.word, rowID: item.id, field: .word)
                + Self.fieldIssues(value: item.reading, rowID: item.id, field: .reading)
                + Self.readingIssues(item: item, supportedCharacters: supportedCharacters)
        }
    }

    private static func fieldIssues(value: String, rowID: UUID, field: Field) -> [Issue] {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.init(rowID: rowID, field: field, reason: .empty, characters: "")]
        }
        let controls = value.unicodeScalars.filter(Self.isControlScalar)
        guard !controls.isEmpty else {
            return []
        }
        return [.init(
            rowID: rowID, field: field, reason: .controlCharacter,
            characters: String(String.UnicodeScalarView(controls))
        )]
    }

    private static func readingIssues(
        item: Config.UserDictionaryEntry,
        supportedCharacters: Set<Character>
    ) -> [Issue] {
        guard !item.reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var unsupported: [Character] = []
        for character in item.reading.toKatakana() where !supportedCharacters.contains(character) {
            if !character.unicodeScalars.contains(where: Self.isControlScalar),
               !unsupported.contains(character) {
                unsupported.append(character)
            }
        }
        guard !unsupported.isEmpty else {
            return []
        }
        return [.init(
            rowID: item.id, field: .reading, reason: .unsupportedCharacter,
            characters: String(unsupported)
        )]
    }

    private static func isControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        // Format scalars such as an emoji's ZWJ are valid word content.
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            true
        default:
            false
        }
    }
}
