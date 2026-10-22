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
        let settings = try #require(initial.first?["settings"] as? [String: Any])
        let compiledDirectory = CompiledUserDictionaryStore.directoryURL(
            memoryDirectoryURL: fixture.dataURL.appendingPathComponent("memory")
        )
        let compiledTextURL = compiledDirectory.appendingPathComponent("user0.loudstxt3")
        let originalDictionary = try Data(contentsOf: compiledTextURL)
        let entry = Config.UserDictionaryEntry(word: "独立保存確認語", reading: "てすと", hint: "固定テスト")
        let encodedEntry = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        // Another setting saved first must survive the dictionary transaction.
        let opened = try fixture.run([["operation": "settings-save", "settings": ["profile": "辞書以外の設定"]]])
        let openedStamp = try #require(fileState(in: opened.first)["stamp"] as? String)
        let saved = try fixture.run([
            ["operation": "dictionary-save", "items": [encodedEntry], "settingsFile": ["expectedStamp": openedStamp]]
        ] + fixture.requestsForCandidates())

        #expect(saved.first?["dictionarySaved"] as? Bool == true)
        #expect(try candidateTexts(in: saved.last).contains(entry.word))
        #expect(try Data(contentsOf: compiledTextURL) != originalDictionary)
        #expect(!FileManager.default.fileExists(atPath: fixture.dataURL.appendingPathComponent("UserDictionary").path))
        let savedContent = try Data(contentsOf: fixture.settingsURL)
        let savedDocument = try #require(try JSONSerialization.jsonObject(with: savedContent) as? [String: Any])
        #expect(savedDocument["profile"] as? String == "辞書以外の設定")
        let savedStamp = try #require(fileState(in: saved.first)["stamp"] as? String)
        #expect(savedStamp != openedStamp)
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
        let failed = try fixture.run([
            ["operation": "dictionary-save", "items": [invalidEntry], "settingsFile": ["expectedStamp": savedStamp]],
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

        let stale = try fixture.run([
            ["operation": "dictionary-save", "items": [encodedEntry], "settingsFile": ["expectedStamp": openedStamp]]
        ])
        #expect(stale.first?["dictionarySaved"] as? Bool == false)
        #expect(stale.first?["dictionarySaveError"] as? String == "persistence")
        #expect((stale.first?["settingsResult"] as? [String: Any])?["error"] != nil)
        #expect(try Data(contentsOf: fixture.settingsURL) == savedContent)
    }

    private func fileState(in response: [String: Any]?) throws -> [String: Any] {
        let result = try #require(response?["settingsResult"] as? [String: Any])
        return try #require(result["file"] as? [String: Any])
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
