@testable import Core
import Foundation
import Testing

enum UserDictionaryExchangeFixture {
    static func content(_ name: String) throws -> Data {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/UserDictionaryExchange")
        return try Data(contentsOf: fixtures.appendingPathComponent(name))
    }

    static func document(_ text: String) throws -> UserDictionaryExchange.Document {
        try UserDictionaryExchange.parse(Data(text.utf8), format: .mozc)
    }

    static func entry(_ row: UserDictionaryExchange.Row) throws -> Config.UserDictionaryEntry {
        try #require(row.item)
    }
}
