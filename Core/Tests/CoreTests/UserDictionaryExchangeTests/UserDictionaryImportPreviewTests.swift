@testable import Core
import Foundation
import Testing

@Suite("辞書取込の確認と適用")
struct UserDictionaryImportPreviewTests {
    @Test("既存優先で重複とヒント衝突を区別しプレビューだけでは変更しない")
    func existingEntriesWinAndIncomingDuplicatesReferToTheFirstAcceptedRow() throws {
        let existing = [Config.UserDictionaryEntry(word: "既存語", reading: "てすと", hint: "旧ヒント")]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(existing)
        let document = try UserDictionaryExchangeFixture.document("""
        テスト\t既存語\t名詞\t旧ヒント
        てすと\t既存語\t名詞\t別ヒント
        じしょ\t追加語\t名詞\t補足
        ジショ\t追加語\t名詞\t補足
        じしょ\t追加語\t名詞\t別の補足
        """)
        let preview = try UserDictionaryImportPreview.make(document: document, existing: existing)
        #expect(preview.rows.map(\.outcome) == [.duplicate, .conflict, .addition, .duplicate, .conflict])
        #expect(preview.counts.additions == 1)
        #expect(preview.counts.duplicates == 2)
        #expect(preview.counts.conflicts == 2)
        #expect(preview.counts.excluded == 0)
        #expect(try encoder.encode(existing) == snapshot)
        #expect(preview.rows[0].existingID == existing[0].id)
        let added = try UserDictionaryExchangeFixture.entry(document.rows[2])
        #expect(preview.rows[3].existingID == added.id)
        let applied = try UserDictionaryImportPreview.applying(preview, to: existing)
        #expect(applied.map(\.id) == [existing[0].id, added.id])
        #expect(applied[0].hint == "旧ヒント")
        #expect(applied[1].reading == "じしょ")
        #expect(applied[1].hint == "補足")
    }

    @Test("不正な行を元行と項目別理由付きで除外し黙って取り込まない")
    func malformedAndInvalidRowsRemainVisibleInThePreview() throws {
        let document = try UserDictionaryExchange.parse(
            UserDictionaryExchangeFixture.content("mozc.txt"), format: .mozc
        )
        let preview = try UserDictionaryImportPreview.make(document: document, existing: [])
        #expect(preview.counts.additions == 2)
        #expect(preview.counts.duplicates == 1)
        #expect(preview.counts.conflicts == 1)
        #expect(preview.counts.excluded == 3)
        #expect(preview.rows[2].source.sourceLine == 4)
        #expect(preview.rows[2].problem == .invalidColumns)
        #expect(preview.rows[3].validationIssues.contains {
            $0.field == .reading && $0.reason == .unsupportedCharacter && $0.characters == "🦊"
        })
        #expect(preview.rows[4].validationIssues.contains { $0.field == .reading && $0.reason == .empty })
        let emptyWord = try UserDictionaryExchangeFixture.document("てすと\t\t名詞")
        let emptyPreview = try UserDictionaryImportPreview.make(document: emptyWord, existing: [])
        #expect(emptyPreview.rows[0].validationIssues.contains { $0.field == .word && $0.reason == .empty })
    }

    @Test("適用直前のID・並び順・生の文字列・ヒントの変更を検出する", arguments: Array(0...7))
    func stalePreviewNeverOverwritesAnEditedDraft(change: Int) throws {
        let original = [
            Config.UserDictionaryEntry(word: "cafe\u{301}", reading: "てすと", hint: nil),
            Config.UserDictionaryEntry(word: "別の語", reading: "じしょ", hint: "ヒント")
        ]
        let document = try UserDictionaryExchangeFixture.document("ついか\t追加語\t名詞")
        let preview = try UserDictionaryImportPreview.make(document: document, existing: original)
        var current = original
        switch change {
        case 0: current[0].id = UUID()
        case 1: current.reverse()
        case 2: current[0].word = "別の単語"
        case 3: current[0].reading = "テスト"
        case 4: current[0].hint = ""
        case 5: current[1].hint = "変更"
        case 6: current.removeLast()
        default: current[0].word = "café"
        }
        #expect(throws: UserDictionaryExchange.Failure.stalePreview) {
            _ = try UserDictionaryImportPreview.applying(preview, to: current)
        }
    }

    @Test("読み以外のUnicode表現を勝手に正規化せず空ヒントと欠落ヒントは同じ意味で比較する")
    func duplicateDetectionOnlyNormalizesTheReading() throws {
        let existing = [
            Config.UserDictionaryEntry(word: "café", reading: "てすと", hint: "café"),
            Config.UserDictionaryEntry(word: "無補足", reading: "じしょ", hint: nil)
        ]
        let imported = [
            Config.UserDictionaryEntry(word: "cafe\u{301}", reading: "テスト", hint: "café"),
            Config.UserDictionaryEntry(word: "café", reading: "テスト", hint: "cafe\u{301}"),
            Config.UserDictionaryEntry(word: "無補足", reading: "ジショ", hint: "")
        ]
        let document = try UserDictionaryExchange.parse(UserDictionaryExchange.export(imported), format: .json)
        let preview = try UserDictionaryImportPreview.make(document: document, existing: existing)
        #expect(preview.rows.map(\.outcome) == [.addition, .conflict, .duplicate])
        let applied = try UserDictionaryImportPreview.applying(preview, to: existing)
        #expect(Array(applied[2].word.utf8) == Array(imported[0].word.utf8))
        #expect(applied[2].reading == "テスト")
        #expect(applied[2].hint == "café")
    }

    @Test("シリアライズしたプレビューに既存辞書のスナップショットを含めない")
    func previewOutputContainsOnlyRowsCountsAndNotices() throws {
        let document = try UserDictionaryExchangeFixture.document("てすと\t合成語\t名詞")
        let preview = try UserDictionaryImportPreview.make(document: document, existing: [])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any])
        #expect(Set(object.keys) == ["rows", "counts", "notices"])
        #expect(preview.notices == [.properNounRegistration])
        let firstApplication = try UserDictionaryImportPreview.applying(preview, to: [])
        let secondApplication = try UserDictionaryImportPreview.applying(preview, to: [])
        #expect(firstApplication.map(\.id) == secondApplication.map(\.id))
    }
}
