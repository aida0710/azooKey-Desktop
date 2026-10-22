#if os(Linux)
import Core
@testable import DesktopBridge
import Foundation
import Testing

@Suite("実bridgeによるユーザー辞書保存")
struct DesktopDictionaryBridgeTests {
    @Test("保存後の新bridgeで登録語が現れ不正保存と古いconfigureでも旧候補を失わない")
    func savedDictionarySurvivesRestartAndFailedReplacement() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let initial = try fixture.run([["operation": "settings"]] + fixture.requestsForCandidates())
        var settings = try #require(initial.first?["settings"] as? [String: Any])
        let compiledDirectory = CompiledUserDictionaryStore.directoryURL(
            memoryDirectoryURL: fixture.dataURL.appendingPathComponent("memory")
        )
        let compiledTextURL = compiledDirectory.appendingPathComponent("user0.loudstxt3")
        let originalDictionary = try Data(contentsOf: compiledTextURL)
        let entry = Config.UserDictionaryEntry(word: "独立保存確認語", reading: "てすと", hint: "固定テスト")
        let encodedEntry = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        settings["userDictionary"] = ["items": [encodedEntry]]
        settings["preservedByDictionarySave"] = ["nested": "辞書以外の設定"]
        let stagedURL = try fixture.stage(settings: settings)
        let saved = try fixture.run([
            ["operation": "dictionary-save", "items": [encodedEntry], "stagedSettingsPath": stagedURL.path]
        ] + fixture.requestsForCandidates())

        #expect(saved.first?["dictionarySaved"] as? Bool == true)
        #expect(try candidateTexts(in: saved.last).contains(entry.word))
        #expect(try Data(contentsOf: compiledTextURL) != originalDictionary)
        #expect(!FileManager.default.fileExists(atPath: fixture.dataURL.appendingPathComponent("UserDictionary").path))
        let savedContent = try Data(contentsOf: fixture.settingsURL)
        let savedDocument = try #require(try JSONSerialization.jsonObject(with: savedContent) as? [String: Any])
        #expect((savedDocument["preservedByDictionarySave"] as? [String: String])?["nested"] == "辞書以外の設定")
        #expect(try backups(in: fixture).isEmpty)

        let restarted = try fixture.run([["operation": "settings"]] + fixture.requestsForCandidates())
        #expect(try candidateTexts(in: restarted.last).contains(entry.word))
        let restartedSettings = try #require(restarted.first?["settings"] as? [String: Any])
        let restartedDictionary = try #require(restartedSettings["userDictionary"] as? [String: Any])
        let restartedItems = try #require(restartedDictionary["items"] as? [[String: Any]])
        #expect(restartedItems.first?["id"] as? String == entry.id.uuidString)

        var invalidEntry = encodedEntry
        invalidEntry["reading"] = "てすと🦊"
        var invalidSettings = settings
        invalidSettings["userDictionary"] = ["items": [invalidEntry]]
        let invalidStage = try fixture.stage(settings: invalidSettings)
        let failed = try fixture.run([
            ["operation": "dictionary-save", "items": [invalidEntry], "stagedSettingsPath": invalidStage.path],
            ["operation": "configure", "settings": invalidSettings]
        ] + fixture.requestsForCandidates())

        #expect(failed.first?["dictionarySaved"] as? Bool == false)
        let issues = try #require(failed.first?["dictionaryIssues"] as? [[String: Any]])
        #expect(issues.first?["rowID"] as? String == entry.id.uuidString)
        #expect(issues.first?["reason"] as? String == "unsupportedCharacter")
        #expect(failed[1]["error"] as? String == "invalid_request")
        #expect(try candidateTexts(in: failed.last).contains(entry.word))
        #expect(try Data(contentsOf: fixture.settingsURL) == savedContent)
        #expect(try backups(in: fixture).isEmpty)

        let afterFailure = try fixture.run(fixture.requestsForCandidates())
        #expect(try candidateTexts(in: afterFailure.last).contains(entry.word))
    }

    private func candidateTexts(in response: [String: Any]?) throws -> [String] {
        let candidates = try #require(response?["candidates"] as? [[String: Any]])
        return candidates.compactMap { $0["text"] as? String }
    }

    private func backups(in fixture: DesktopDictionaryBridgeFixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: fixture.settingsURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".dictionary-settings-backup-") }
    }
}
#endif
