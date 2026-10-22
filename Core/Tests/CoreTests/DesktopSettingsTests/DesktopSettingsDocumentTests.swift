import Foundation
import Testing

@testable import Core

@Suite("設定文書の読み取りと検証")
struct DesktopSettingsDocumentTests {
    private func read(_ text: String, over knownGood: DesktopSettings = DesktopSettingsFixture.known) throws -> DesktopSettings {
        try DesktopSettingsDocument.settings(from: Data(text.utf8), over: knownGood)
    }

    @Test("型の違い・未知の項目・範囲外の値をCoreへ渡す前に拒否する")
    func wrongTypesUnknownKeysAndValuesAreRejected() {
        let malformed = [
            "[]", "null", #"{"live":1}"#, #"{"tree":"true"}"#, #"{"inferenceLimit":true}"#,
            #"{"inferenceLimit":0}"#, #"{"inferenceLimit":101}"#, #"{"inferenceLimit":5.0}"#, #"{"punctuation":"1"}"#,
            #"{"punctuation":5}"#, #"{"learning":"sometimes"}"#, #"{"newSetting":1}"#,
            #"{"aiEndpoint":"file:///tmp/model"}"#, #"{"aiEndpoint":"https://"}"#,
            #"{"transformShortcut":{"key":"s","modifiers":16}}"#, #"{"transformShortcut":{"key":"","modifiers":2}}"#,
            #"{"transformShortcut":{"key":"s","modifiers":2,"extra":1}}"#,
            #"{"userDictionary":{"items":[{"word":"欠落"}]}}"#, #"{"customTable":10}"#, #"{"inputStyle":"custom"}"#,
            #"{"aiPromptLanguage":"fr"}"#, #"{"aiPromptLanguage":"english"}"#, #"{"aiPromptLanguage":1}"#,
            #"{"profile":"\ud800"}"#, #"{"profile":"\#(String(repeating: "あ", count: 4097))"}"#
        ]
        for document in malformed {
            #expect(settingsProblem { _ = try read(document) } != nil, "\(document.prefix(80))")
        }
    }

    @Test("問題の種類と項目名を画面が示せる形で返す")
    func problemsNameTheField() {
        #expect(settingsProblem { _ = try read(#"{"live":1}"#) } == .invalidValue("live"))
        #expect(settingsProblem { _ = try read(#"{"newSetting":1}"#) } == .unknownKey("newSetting"))
        #expect(settingsProblem { _ = try read(#"{"live":false,"live":true}"#) } == .invalidValue("live"))
        #expect(settingsProblem { _ = try read(#"["not an object"]"#) } == .invalidValue(""))
        #expect(settingsProblem { _ = try read(#"{"userDictionary":{"items":[{"id":"x","word":"語","reading":"ご"}]}}"#) }
            == .invalidValue("userDictionary.items[0].id"))
        #expect(settingsProblem { _ = try read(#"{"transformShortcut":{"key":"s","modifiers":2,"extra":1}}"#) }
            == .unknownKey("transformShortcut.extra"))
        #expect(settingsProblem { _ = try read(#"{"\#(String(repeating: "k", count: 300))":1}"#) }?.arguments["field"]?.count == 100)
    }

    @Test("JSONの構文の誤りは行と列を文字単位で示す")
    func syntaxErrorsReportLineAndColumn() {
        #expect(settingsProblem { _ = try read("{") } == .init(.invalidJSON, arguments: ["line": "1", "column": "2"]))
        #expect(settingsProblem { _ = try read("{\n  \"profile\": \"日本\" x}") }
            == .init(.invalidJSON, arguments: ["line": "2", "column": "19"]))
        #expect(settingsProblem { _ = try read("\u{FEFF}{}") } == .init(.invalidJSON, arguments: ["line": "1", "column": "1"]))
    }

    @Test("深すぎる入れ子と不正なUTF-8は落ちずに問題として返す")
    func deepNestingAndInvalidEncodingAreProblems() {
        let deep = #"{"profile":"# + String(repeating: "[", count: 1200) + "0" + String(repeating: "]", count: 1200) + "}"
        #expect(settingsProblem { _ = try read(deep) } == .init(.invalidStructure))
        let invalidUTF8 = Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D])
        #expect(settingsProblem { _ = try DesktopSettingsDocument.settings(from: invalidUTF8, over: .defaults) } == .init(.readFailed))
    }

    @Test("結合文字を含むプロフィールはCoreと同じ文字数で上限を数える")
    func profileLimitCountsCharacters() throws {
        let profile = String(repeating: "か\u{3099}", count: 4096)
        #expect(try read(#"{"profile":"\#(profile)"}"#).profile == profile)
    }

    @Test("重複した辞書IDを拒否する")
    func duplicateDictionaryIdentifiersAreRejected() {
        var settings = DesktopSettingsFixture.known
        settings.userDictionary.items += settings.userDictionary.items
        #expect(settingsProblem { try settings.validate() } == .invalidValue("userDictionary.items[1].id"))
    }

    @Test("一部だけの文書は書かれていない項目を正常な値のまま保つ")
    func partialDocumentKeepsOtherValues() throws {
        let settings = try read(#"{"live":true}"#)
        #expect(settings.live)
        #expect(settings.userDictionary.items.map(\.id) == [DesktopSettingsFixture.entryID])
        #expect(settings.profile == "テスト")
    }

    @Test("入力・表示の既定化は辞書・AI・学習・カスタム表を保つ")
    func inputDefaultsPreserveDictionaryAILearningAndCustomTable() {
        var values = DesktopSettingsFixture.known
        values.customTable = "synthetic custom table"
        let reset = values.resettingInputPreferences()
        #expect(reset.tree)
        #expect(reset.live)
        #expect(!reset.halfSpace)
        for key in ["userDictionary", "aiEnabled", "aiModel", "aiEndpoint", "includeContext",
                    "transformShortcut", "aiPromptLanguage", "learning", "profile", "personalization", "customTable"] {
            #expect(reset.value(forKey: key) == values.value(forKey: key), "\(key)")
        }
    }

    @Test("既定の指示の言語は既定で英語と書き、ja と en だけを読む")
    func promptLanguageDefaultsToEnglishAndReadsItsCodes() throws {
        #expect(DesktopSettings.defaults.aiPromptLanguage == .english)
        let written = try #require(String(data: DesktopSettingsDocument.data(for: .defaults), encoding: .utf8))
        #expect(written.contains(#""aiPromptLanguage": "en""#))
        #expect(try read(#"{"aiPromptLanguage":"ja"}"#, over: .defaults).aiPromptLanguage == .japanese)
        #expect(try read(#"{"aiPromptLanguage":"en"}"#).aiPromptLanguage == .english)
        #expect(try read(#"{"live":true}"#).aiPromptLanguage == DesktopSettingsFixture.known.aiPromptLanguage,
                "a document without the setting keeps the known value")
        #expect(settingsProblem { _ = try read(#"{"aiPromptLanguage":"fr"}"#) } == .invalidValue("aiPromptLanguage"))
    }

    @Test("書き出した文書は読み戻すと同じ値になり日本語をそのまま書く")
    func serializedDocumentRoundTrips() throws {
        var values = DesktopSettingsFixture.known
        values.userDictionary.items[0].nonNullHint = "1行目\n2行目\t補足"
        let data = DesktopSettingsDocument.data(for: values)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"word\": \"試験\""))
        #expect(text.contains(#""hint": "1行目\n2行目\t補足""#))
        #expect(try DesktopSettingsDocument.settings(from: data, over: .defaults) == values)
        let withoutHint = DesktopSettingsDocument.data(for: DesktopSettingsFixture.known)
        #expect(try #require(String(data: withoutHint, encoding: .utf8)).contains("hint") == false)
    }
}
