@testable import Core
import Foundation
import Testing

@Suite("ユーザー辞書の入力検証")
struct UserDictionaryValidationTests {
    @Test("空欄・制御文字・対応しない読みを元の行IDと項目で返す")
    func invalidRowsKeepTheirIdentityAndReason() throws {
        let fixture = try DictionaryTransactionFixture()
        let emptyWord = Config.UserDictionaryEntry(word: "　 ", reading: "てすと")
        let emptyReading = Config.UserDictionaryEntry(word: "単語", reading: "\n ")
        let unsupported = Config.UserDictionaryEntry(word: "単語", reading: "てすと🦊")
        let control = Config.UserDictionaryEntry(word: "単\0語", reading: "テスト")
        let issues = try UserDictionaryValidation.validate(
            items: [emptyWord, emptyReading, unsupported, control],
            charIDFileURL: fixture.characterURL
        )
        #expect(issues == [
            .init(rowID: emptyWord.id, field: .word, reason: .empty),
            .init(rowID: emptyReading.id, field: .reading, reason: .empty),
            .init(rowID: unsupported.id, field: .reading, reason: .unsupportedCharacter, characters: "🦊"),
            .init(rowID: control.id, field: .word, reason: .controlCharacter, characters: "\0")
        ])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(issues)) as? [[String: Any]]
        #expect(json?[2]["rowID"] as? String == unsupported.id.uuidString)
        #expect(json?[2]["field"] as? String == "reading")
        #expect(json?[2]["reason"] as? String == "unsupportedCharacter")
    }

    @Test("ひらがなを同じ文字表で検証し単語中の絵文字の結合文字を保持する")
    func validWordsAndNormalizedReadingsAreAccepted() throws {
        let fixture = try DictionaryTransactionFixture()
        let items = [
            Config.UserDictionaryEntry(word: "👨‍👩‍👧‍👦", reading: "てすと"),
            Config.UserDictionaryEntry(word: "別の単語", reading: "テスト")
        ]
        #expect(try UserDictionaryValidation.validate(
            items: items, charIDFileURL: fixture.characterURL
        ).isEmpty)
        #expect(items[0].reading == "てすと")
        #expect(try UserDictionaryValidation.validate(items: [], charIDFileURL: nil).isEmpty)
    }

    @Test("無効な行を除外して部分的に保存せず旧辞書と旧設定を保つ")
    func invalidSaveDoesNotCompileOrPersistAnyRows() async throws {
        let fixture = try DictionaryTransactionFixture()
        let previousFiles = try fixture.files()
        let previousSettings = try Data(contentsOf: fixture.settingsURL)
        let invalid = Config.UserDictionaryEntry(word: "", reading: "てすと")
        do {
            try await UserDictionarySaveTransaction.save(
                request: .init(
                    items: fixture.newItems + [invalid], systemItems: [],
                    directoryURL: fixture.directoryURL, charIDFileURL: fixture.characterURL
                ),
                persistence: fixture.persistence(), activate: {},
                operations: UserDictionaryFileOperations()
            )
            Issue.record("An invalid row was saved")
        } catch let error as UserDictionarySaveError {
            #expect(error.phase == .validation)
            let invalidEntries = try #require(error.underlying as? UserDictionaryValidation.InvalidEntries)
            #expect(invalidEntries.issues.first?.rowID == invalid.id)
            #expect(error.rollbackFailures.isEmpty)
        }
        #expect(try fixture.files() == previousFiles)
        #expect(try Data(contentsOf: fixture.settingsURL) == previousSettings)
    }
}
