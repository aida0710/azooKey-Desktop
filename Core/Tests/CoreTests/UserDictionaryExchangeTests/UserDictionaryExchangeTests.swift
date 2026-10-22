@testable import Core
import Foundation
import Testing

@Suite("ユーザー辞書の可逆JSON")
struct UserDictionaryExchangeTests {
    @Test("JSON往復で元の読み・単語・タブと改行を含むヒントをそのまま保つ")
    func jsonRoundTripPreservesRawFieldsAndCreatesNewRowIdentifiers() throws {
        let entries = [
            Config.UserDictionaryEntry(word: "語\t改行\n🙂e\u{301}", reading: "てすと", hint: "補足\t改行\r\n\u{0}"),
            Config.UserDictionaryEntry(word: "空ヒント", reading: "テスト", hint: ""),
            Config.UserDictionaryEntry(word: "ヒントなし", reading: "てすと", hint: nil)
        ]
        let content = try UserDictionaryExchange.export(entries)
        #expect(String(data: content, encoding: .utf8) != nil)
        let document = try UserDictionaryExchange.parse(content, format: .json)
        #expect(document.rows.count == entries.count)
        for (offset, row) in document.rows.enumerated() {
            let restored = try UserDictionaryExchangeFixture.entry(row)
            #expect(Array(restored.word.utf8) == Array(entries[offset].word.utf8))
            #expect(Array(restored.reading.utf8) == Array(entries[offset].reading.utf8))
            #expect(restored.hint.map { Array($0.utf8) } == entries[offset].hint.map { Array($0.utf8) })
            #expect(restored.id != entries[offset].id)
            #expect(row.sourceLine == nil)
            #expect(row.sourceIndex == offset + 1)
        }
        let object = try #require(try JSONSerialization.jsonObject(with: content) as? [String: Any])
        #expect(object["format"] as? String == "azookey-user-dictionary")
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.allSatisfy { $0["id"] == nil })
    }

    @Test("未知形式・未来版・型違い・未知フィールド・必要項目欠落を明示して拒否する",
          arguments: [
            #"{"format":"other","version":1,"items":[]}"#,
            #"{"format":"azookey-user-dictionary","version":2,"items":[]}"#,
            #"{"format":"azookey-user-dictionary","version":true,"items":[]}"#,
            #"{"format":"azookey-user-dictionary","version":1,"items":[{"word":"語"}]}"#,
            #"{"format":"azookey-user-dictionary","version":1,"items":[{"word":"語","reading":"ご","pos":"動詞"}]}"#,
            #"{"format":"azookey-user-dictionary","version":1,"items":[],"extra":1}"#,
            "not JSON"
          ])
    func unsupportedJSONCannotBeSilentlyInterpreted(text: String) throws {
        #expect(throws: UserDictionaryExchange.Failure.self) {
            _ = try UserDictionaryExchange.parse(Data(text.utf8), format: .json)
        }
    }

    @Test("空の辞書も明示した形式と版で往復できる")
    func emptyDictionaryRoundTrips() throws {
        let content = try UserDictionaryExchange.export([])
        let document = try UserDictionaryExchange.parse(content, format: .json)
        #expect(document.rows.isEmpty)
    }

    @Test("JSONのヒントに含まれるDELとC1制御文字をバイナリと誤判定せず往復する",
          arguments: ["\u{7F}", "\u{85}", "\u{9F}"])
    func jsonHintsPreserveControlsThatTheEncoderDoesNotEscape(control: String) throws {
        let entries = [Config.UserDictionaryEntry(word: "合成語", reading: "てすと", hint: "前" + control + "後")]
        let content = try UserDictionaryExchange.export(entries)
        let document = try UserDictionaryExchange.parse(content, format: .json)
        let restored = try UserDictionaryExchangeFixture.entry(document.rows[0])
        #expect(restored.hint.map { Data($0.utf8) } == entries[0].hint.map { Data($0.utf8) })
        #expect(try UserDictionaryExchange.export([restored]) == content)
        let preview = try UserDictionaryImportPreview.make(document: document, existing: [])
        #expect(preview.counts.additions == 1)
        #expect(preview.counts.excluded == 0)
    }

    @Test("JSON文字列に許されない生のNULは文字コード復号後に拒否する")
    func invalidUnescapedJSONControlsAreStillRejected() throws {
        let text = "{\"format\":\"azookey-user-dictionary\",\"version\":1,\"items\":[{\"reading\":\"てすと\",\"word\":\"語\",\"hint\":\"\u{0}\"}]}"
        #expect(throws: UserDictionaryExchange.Failure.invalidDocument) {
            _ = try UserDictionaryExchange.parse(Data(text.utf8), format: .json)
        }
    }
}
