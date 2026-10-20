#if os(Linux)
import Core
import Foundation
import Testing

@Suite("実bridgeによる辞書の取込と書出し")
struct DesktopDictionaryExchangeBridgeTests {
    @Test("プレビューと書出しは設定を保存せず読み単語ヒントを保持する")
    func previewAndExportKeepDraftSeparateFromSavedSettings() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let imported = Config.UserDictionaryEntry(word: "交換確認語", reading: "こうかん", hint: "タブ\t改行\nを保持")
        let source = fixture.rootURL.appendingPathComponent("dictionary.json")
        let content = try UserDictionaryExchange.export([imported])
        try content.write(to: source)
        let existing = Config.UserDictionaryEntry(word: "既存確認語", reading: "きぞん", hint: nil)
        let entries = try jsonEntries([existing])
        let replies = try fixture.run([
            ["operation": "dictionary-import-preview", "importPath": source.path,
             "importFormat": "json", "importEncoding": "automatic", "items": entries],
            ["operation": "dictionary-export", "items": entries]
        ])
        let preview = try #require(replies[0]["dictionaryImportPreview"] as? [String: Any])
        let counts = try #require(preview["counts"] as? [String: Int])
        #expect(counts["additions"] == 1)
        #expect(preview["original"] == nil)
        let draft = try #require(replies[0]["dictionaryImportItems"] as? [[String: Any]])
        #expect(draft.count == 2)
        #expect(draft[0]["id"] as? String == existing.id.uuidString)
        #expect(draft[1]["word"] as? String == imported.word)
        #expect(draft[1]["reading"] as? String == imported.reading)
        #expect(draft[1]["hint"] as? String == imported.hint)
        #expect(try Data(contentsOf: source) == content)
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.dataURL.path))
        let exported = try #require(replies[1]["dictionaryExportJSON"] as? String)
        let roundtrip = try UserDictionaryExchange.parse(Data(exported.utf8), format: .json)
        #expect(roundtrip.rows.first?.item?.word == existing.word)
        #expect(roundtrip.rows.first?.item?.reading == existing.reading)
        #expect(roundtrip.rows.first?.item?.hint == nil)
    }

    @Test("未対応の版や文字コードと読めないファイルは内容を含まない理由だけ返す")
    func importFailuresNeverExposeFileContentOrPaths() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let source = fixture.rootURL.appendingPathComponent("PRIVATE_SOURCE.json")
        try Data("{\"format\":\"azookey-user-dictionary\",\"version\":99,\"items\":[]}".utf8).write(to: source)
        let requests: [[String: Any]] = [source.path, source.path + ".missing"].map { path in
            ["operation": "dictionary-import-preview", "importPath": path,
             "importFormat": "json", "importEncoding": "automatic", "items": []]
        }
        let replies = try fixture.run(requests)
        #expect(replies[0]["dictionaryExchangeError"] as? String == "unsupportedVersion")
        #expect(replies[1]["dictionaryExchangeError"] as? String == "importFailed")
        let encoded = try JSONSerialization.data(withJSONObject: replies)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_SOURCE"))
        #expect(replies.allSatisfy { $0["dictionaryImportItems"] == nil })
    }

    private func jsonEntries(_ entries: [Config.UserDictionaryEntry]) throws -> [[String: Any]] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)) as? [[String: Any]])
    }
}
#endif
