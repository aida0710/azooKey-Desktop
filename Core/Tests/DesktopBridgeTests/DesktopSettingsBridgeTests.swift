#if os(Linux)
import Core
import Foundation
import Testing

@Suite("実bridgeによる設定ファイルの操作")
struct DesktopSettingsBridgeTests {
    private func result(_ response: [String: Any]?) throws -> [String: Any] {
        try #require(response?["settingsResult"] as? [String: Any])
    }

    private func file(_ response: [String: Any]?) throws -> [String: Any] {
        try #require(try result(response)["file"] as? [String: Any])
    }

    @Test("壊れたファイルは場所と理由を返し復旧すると元のファイルを退避して次の再読み込みで使える")
    func brokenFileIsReportedAndRecovered() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let original = Data(#"{"live":"yes"}"#.utf8)
        try original.write(to: fixture.settingsURL)
        let responses = try fixture.run([
            ["operation": "settings-load"],
            ["operation": "settings-reload"],
            ["operation": "settings-recover", "settingsFile": ["useDefaults": true]],
            ["operation": "settings-reload"]
        ])
        let loaded = try file(responses[0])
        #expect(loaded["path"] as? String == fixture.settingsURL.path)
        let problem = try #require(loaded["problem"] as? [String: Any])
        #expect(problem["message"] as? String == "settings.invalid_value")
        #expect((problem["arguments"] as? [String: String])?["field"] == "live")
        #expect(try file(responses[1])["problem"] != nil)
        let saved = try #require(try result(responses[2])["saved"] as? [String: Any])
        let recoveredPath = try #require(saved["recoveredPath"] as? String)
        #expect(try Data(contentsOf: URL(fileURLWithPath: recoveredPath)) == original)
        #expect((responses[2]["settings"] as? [String: Any])?["live"] as? Bool == true)
        #expect(try file(responses[3])["problem"] == nil)
    }

    @Test("変換器が辞書を組めない版は拒否の理由を返しファイルを変えない")
    func converterRejectionIsReported() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let entry = #"{"id":"6C5FCE13-FB0F-4B59-9281-F7347AE8F91C","word":"語","reading":"てすと🦊"}"#
        let document = Data((#"{"userDictionary":{"items":["# + entry + "]}}").utf8)
        try document.write(to: fixture.settingsURL)
        let responses = try fixture.run([["operation": "settings-reload"], ["operation": "settings-reload"]])
        for response in responses {
            let problem = try #require(try file(response)["problem"] as? [String: Any])
            #expect(problem["code"] as? String == "engineRejected")
        }
        #expect(try Data(contentsOf: fixture.settingsURL) == document)
    }

    @Test("開いた後に別の画面が保存していたら上書きせず競合を返す")
    func staleSaveIsRefused() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let responses = try fixture.run([
            ["operation": "settings-load"],
            ["operation": "settings-save", "settings": ["live": false]],
            ["operation": "settings-save", "settings": ["live": true], "settingsFile": ["expectedStamp": "absent"]],
            ["operation": "settings-save", "settings": ["inferenceLimit": "x"]]
        ])
        #expect(try file(responses[0])["exists"] as? Bool == false)
        #expect(try file(responses[0])["stamp"] as? String == "absent")
        #expect(try result(responses[1])["error"] == nil)
        let conflict = try #require(try result(responses[2])["error"] as? [String: Any])
        #expect(conflict["code"] as? String == "changed")
        let invalid = try #require(try result(responses[3])["error"] as? [String: Any])
        #expect((invalid["arguments"] as? [String: String])?["field"] == "inferenceLimit")
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.settingsURL)) as? [String: Any])
        #expect(saved["live"] as? Bool == false)
    }

    @Test("保存した既定の指示の言語を同じbridgeの指示の履歴がすぐに使う")
    func savedPromptLanguageReachesTheInstructionHistory() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let field: [String: Any] = ["identity": ["/input/1", "fixture"], "hasSurroundingUpdate": true, "isSensitive": false,
                                    "surrounding": ["text": "前 原文 後", "cursorUTF16": 4, "anchorUTF16": 2]]
        let open: [String: Any] = ["operation": "ai-transform-open", "context": "field", "ai": ["field": field]]
        let responses = try fixture.run([
            ["operation": "settings-save", "settings": ["aiEnabled": true]],
            open,
            ["operation": "settings-save", "settings": ["aiPromptLanguage": "ja"]],
            open
        ])
        let prompts = responses.map { ($0["history"] as? [[String: Any]])?.compactMap { $0["prompt"] as? String } }
        #expect(prompts[1] == AIPromptHistory.defaultPrompts(in: .english))
        #expect(prompts[3] == AIPromptHistory.defaultPrompts(in: .japanese))
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.settingsURL)) as? [String: Any])
        #expect(saved["aiPromptLanguage"] as? String == "ja")
    }
}
#endif
