import Foundation

enum UserDictionaryJSONExchange {
    private static let formatName = "azookey-user-dictionary"
    private static let currentVersion = 1

    private struct File: Codable {
        let format: String
        let version: Int
        let items: [Item]
    }

    private struct Item: Codable {
        let reading: String
        let word: String
        let hint: String?
    }

    static func export(_ entries: [Config.UserDictionaryEntry]) throws -> Data {
        let file = File(
            format: formatName, version: currentVersion,
            items: entries.map { Item(reading: $0.reading, word: $0.word, hint: $0.hint) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    static func parse(_ text: String) throws -> [UserDictionaryExchange.Row] {
        let content = Data(text.utf8)
        let file: File
        do {
            let object = try JSONSerialization.jsonObject(with: content)
            guard let root = object as? [String: Any], Set(root.keys) == ["format", "version", "items"],
                  let items = root["items"] as? [[String: Any]],
                  items.allSatisfy({ Set($0.keys).isSubset(of: ["reading", "word", "hint"]) }) else {
                throw UserDictionaryExchange.Failure.invalidDocument
            }
            file = try JSONDecoder().decode(File.self, from: content)
        } catch {
            throw UserDictionaryExchange.Failure.invalidDocument
        }
        guard file.format == formatName else {
            throw UserDictionaryExchange.Failure.unsupportedFormat
        }
        guard file.version == currentVersion else {
            throw UserDictionaryExchange.Failure.unsupportedVersion(file.version)
        }
        return file.items.enumerated().map { index, item in
            UserDictionaryExchange.Row(
                sourceIndex: index + 1, sourceLine: nil,
                item: Config.UserDictionaryEntry(word: item.word, reading: item.reading, hint: item.hint),
                partOfSpeech: nil, problem: nil
            )
        }
    }
}
